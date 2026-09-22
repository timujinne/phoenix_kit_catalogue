defmodule PhoenixKitCatalogue.Web.EditViewingLanguageTest do
  @moduledoc """
  An edit form opens on the language tab of the language the admin is
  viewing the page in (boss via Max, 2026-09-21: "if you are in English and
  you click edit on something then ideally you would be editing the English
  version"). A new record still starts on the main language, which holds
  its required fields.

  The page language is set the way production's locale hook sets it
  (`with_request_locale/2`), and the open tab is read from the rendered
  name input: the main language posts `x[name]`, any other `x[lang_name]`.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitCatalogue.Web.Helpers

  @base "/en/admin/catalogue"

  describe "viewing_language/2" do
    test "the exact code, else the first sharing its base, else nil" do
      enabled = ["en-US", "fr-FR", "fr-CA", "et-EE"]

      assert Helpers.viewing_language(enabled, "fr-CA") == "fr-CA"
      assert Helpers.viewing_language(enabled, "fr") == "fr-FR"
      assert Helpers.viewing_language(enabled, "et_EE") == "et-EE"
      assert Helpers.viewing_language(enabled, "EN") == "en-US"
      assert Helpers.viewing_language(enabled, "de-DE") == nil
      assert Helpers.viewing_language(enabled, nil) == nil
    end
  end

  describe "edit forms" do
    setup %{conn: conn} do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("fr-FR")

      catalogue = fixture_catalogue(%{name: "Kitchen"})
      category = fixture_category(catalogue, %{name: "Doors"})
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Hinge"})

      %{conn: conn, catalogue: catalogue, category: category, item: item}
    end

    test "viewed in French, each edit form opens on the French tab", %{conn: conn} = ctx do
      conn = with_request_locale(conn, "fr-FR")

      for {path, prefix} <- edit_paths(ctx) do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(name="#{prefix}[lang_name]"), path
        refute html =~ ~s(name="#{prefix}[name]"), path
      end
    end

    test "viewed in the main language, each edit form opens on the main tab",
         %{conn: conn} = ctx do
      conn = with_request_locale(conn, "en-US")

      for {path, prefix} <- edit_paths(ctx) do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(name="#{prefix}[name]"), path
      end
    end

    test "a page language with no content language to match stays on the main tab",
         %{conn: conn} = ctx do
      conn = with_request_locale(conn, "de-DE")

      for {path, prefix} <- edit_paths(ctx) do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(name="#{prefix}[name]"), path
      end
    end

    test "a NEW record starts on the main tab whatever the page language", %{
      conn: conn,
      catalogue: catalogue
    } do
      conn = with_request_locale(conn, "fr-FR")

      for {path, prefix} <- [
            {"#{@base}/new", "catalogue"},
            {"#{@base}/#{catalogue.uuid}/categories/new", "category"},
            {"#{@base}/#{catalogue.uuid}/items/new", "item"}
          ] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(name="#{prefix}[name]"), path
      end
    end

    test "the French tab saves French and leaves the main name alone", %{
      conn: conn,
      item: item
    } do
      {:ok, view, _html} =
        live(with_request_locale(conn, "fr-FR"), "#{@base}/items/#{item.uuid}/edit")

      view
      |> form(~s(form[action="#"][phx-submit=save]), %{"item" => %{"lang_name" => "Charnière"}})
      |> render_submit()

      saved = PhoenixKitCatalogue.Catalogue.get_item!(item.uuid)
      assert saved.name == "Hinge"
      assert saved.data["fr-FR"]["_name"] == "Charnière"
    end
  end

  defp edit_paths(%{catalogue: catalogue, category: category, item: item}) do
    [
      {"#{@base}/#{catalogue.uuid}/edit", "catalogue"},
      {"#{@base}/categories/#{category.uuid}/edit", "category"},
      {"#{@base}/items/#{item.uuid}/edit", "item"}
    ]
  end
end
