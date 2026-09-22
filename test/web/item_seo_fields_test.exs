defmodule PhoenixKitCatalogue.Web.ItemSeoFieldsTest do
  @moduledoc """
  The item form hides its URL slug, SEO title and SEO description unless
  Settings → Catalogue shows them (boss via Max, 2026-09-21: "not needed
  for the current client, they're just cluttering up the UI").

  Hidden is not gone: a save must keep what they hold.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Settings

  setup %{conn: conn, scope: scope} do
    on_exit(fn -> Settings.update_seo_fields_visible(false) end)

    catalogue = fixture_catalogue(%{name: "SEO cat"})
    item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Oak panel", sku: "OAK-1"})

    # Written through the form itself, with the fields shown — so the text
    # sits wherever the form keeps it, not where a fixture guesses.
    conn = with_scope(conn, scope)
    {:ok, _} = Settings.update_seo_fields_visible(true)
    {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

    view
    |> form("#item-form", %{
      "item" => %{"seo_title" => "Kept title", "seo_description" => "Kept text"}
    })
    |> render_submit()

    {:ok, _} = Settings.update_seo_fields_visible(false)

    %{conn: conn, item: item}
  end

  defp edit(conn, item) do
    {:ok, view, html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")
    {view, html}
  end

  # What the form shows in the SEO fields — the reader the form itself uses.
  defp seo_shown(conn, item) do
    {:ok, _} = Settings.update_seo_fields_visible(true)
    {_view, html} = edit(conn, item)
    {:ok, _} = Settings.update_seo_fields_visible(false)
    {html =~ "Kept title", html =~ "Kept text"}
  end

  test "hidden by default: no slug or SEO inputs a person can see", %{conn: conn, item: item} do
    {_view, html} = edit(conn, item)

    refute html =~ "URL slug"
    refute html =~ "SEO title"
    refute html =~ "SEO description"
  end

  test "a save with the fields hidden keeps what they hold", %{conn: conn, item: item} do
    {view, _html} = edit(conn, item)
    slug_before = Catalogue.get_item(item.uuid).slug

    view |> form("#item-form", %{"item" => %{"name" => "Oak panel 18mm"}}) |> render_submit()

    saved = Catalogue.get_item(item.uuid)
    assert saved.name == "Oak panel 18mm"
    assert seo_shown(conn, item) == {true, true}
    assert saved.slug == slug_before
  end

  # The bug under this change, visible fields or not: a single-language
  # install stored the SEO text flat in `data`, the form read it back from a
  # per-language map that is empty there, showed blanks, and the next save
  # posted the blanks over the text.
  test "shown, a second save leaves the SEO text alone", %{conn: conn, item: item} do
    {:ok, _} = Settings.update_seo_fields_visible(true)

    {view, _html} = edit(conn, item)
    view |> form("#item-form", %{"item" => %{"name" => "Oak panel 2"}}) |> render_submit()

    assert seo_shown(conn, item) == {true, true}
  end

  test "Settings brings them back, with their contents", %{conn: conn, item: item} do
    {:ok, _} = Settings.update_seo_fields_visible(true)
    {_view, html} = edit(conn, item)

    assert html =~ "URL slug"
    assert html =~ "SEO title"
    assert html =~ "Kept title"
  end

  # The hidden slug input echoes whatever the last validate generated, and
  # the generated slug used to count as the user's own: the first debounced
  # keystroke fixed it, and "Birch board" saved as `bi` — invisibly, with the
  # field hidden.
  describe "a new item's slug follows its name" do
    defp new_item_view(conn) do
      catalogue = fixture_catalogue(%{name: "Slug cat"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}/items/new")
      {view, catalogue}
    end

    defp saved_slug(catalogue, name) do
      [item] =
        Catalogue.list_items_for_catalogue(catalogue.uuid)
        |> Enum.filter(&(&1.name == name))

      item.slug
    end

    test "hidden: a later name replaces the slug an earlier keystroke derived", %{conn: conn} do
      {view, catalogue} = new_item_view(conn)

      view |> form("#item-form", %{"item" => %{"name" => "Bi"}}) |> render_change()
      view |> form("#item-form", %{"item" => %{"name" => "Birch board"}}) |> render_change()
      view |> form("#item-form", %{"item" => %{"name" => "Birch board"}}) |> render_submit()

      assert Map.values(saved_slug(catalogue, "Birch board")) == ["birch-board"]
    end

    test "shown: a slug the person typed stays theirs", %{conn: conn} do
      {:ok, _} = Settings.update_seo_fields_visible(true)
      {view, catalogue} = new_item_view(conn)

      view |> form("#item-form", %{"item" => %{"name" => "Oa"}}) |> render_change()
      lang = slug_input_lang(view)

      view
      |> form("#item-form", %{"item" => %{"name" => "Oak panel", "slug" => %{lang => "my-slug"}}})
      |> render_submit()

      assert saved_slug(catalogue, "Oak panel") == %{lang => "my-slug"}
    end

    # The language key the form rendered its slug input under.
    defp slug_input_lang(view) do
      [_, lang] = Regex.run(~r/name="item\[slug\]\[([^\]]+)\]"/, render(view))
      lang
    end
  end

  test "the settings page switch writes the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/settings/catalogue")

    view |> form("#catalogue-seo-fields-form", %{"value" => "true"}) |> render_change()
    assert Settings.seo_fields_visible?()

    view |> form("#catalogue-seo-fields-form", %{"value" => "false"}) |> render_change()
    refute Settings.seo_fields_visible?()
  end
end
