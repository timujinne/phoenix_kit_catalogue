defmodule PhoenixKitCatalogue.Web.ExtensionSlotTest do
  @moduledoc """
  LiveView tests for the item/category form extension slot (Block 1, Task
  4) — `PhoenixKitCatalogue.Extension` + `Extensions`, wired into
  `ItemFormLive` and `CategoryFormLive`. Uses `PhoenixKitCatalogue.Test.FakeExtension`
  (namespace `"fake"`, requires a non-blank `note`) so the round trip is
  exercised without depending on `phoenix_kit_ecommerce`.

  Mutates the process-global `PhoenixKit.ModuleRegistry`, so every test
  starts its own instance via `start_supervised!/1` — same pattern as
  `PhoenixKitCatalogue.ExtensionsTest` and `supplier_comments_test.exs`.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.FakeModule
  alias PhoenixKitCatalogue.Web.Settings

  @base "/en/admin/catalogue"

  defp edit_item_url(uuid), do: "#{@base}/items/#{uuid}/edit"
  defp edit_category_url(uuid), do: "#{@base}/categories/#{uuid}/edit"

  # Same normalization used to produce `test/fixtures/item_form_no_ext.html`
  # — strips the per-mount CSRF token, LiveView session/static tokens,
  # random `phx-*` DOM/upload-ref ids, and the item's UUID, none of which
  # are stable across test runs.
  defp normalize(html) do
    html
    |> String.replace(~r/data-phx-session="[^"]*"/, ~s(data-phx-session="S"))
    |> String.replace(~r/data-phx-static="[^"]*"/, ~s(data-phx-static="S"))
    |> String.replace(~r/name="csrf-token" content="[^"]*"/, ~s(name="csrf-token" content="C"))
    |> String.replace(
      ~r/name="_csrf_token" type="hidden" hidden="" value="[^"]*"/,
      ~s(name="_csrf_token" type="hidden" hidden="" value="C")
    )
    |> String.replace(
      ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/,
      "UUID"
    )
    |> String.replace(~r/(?<=")phx-[A-Za-z0-9_-]{6,}(?=")/, "phx-ID")
    # Core's "[dev]" header tag follows the machine's hostname, so the
    # snapshot would pass or fail by whose computer runs it.
    |> String.replace(~r{<span class="[^"]*">\s*\[dev\]\s*</span>}, "")
    # The supplier picker lists whatever suppliers the test database holds;
    # the snapshot is about the form's shape, not that data.
    |> String.replace(
      ~r{(<select id="supplier-add-picker"[^>]*>).*?</select>}s,
      "\\1</select>"
    )
  end

  describe "no extension registered" do
    test "the item form renders exactly as before the extension slot existed", %{conn: conn} do
      # Fresh, empty registry — no `catalogue_extensions/0` exporter.
      start_supervised!(PhoenixKit.ModuleRegistry)

      # The fixture predates the Settings switch that hides the slug and SEO
      # inputs; with it on, the form is still exactly that page. The hidden
      # default is pinned in test/web/item_seo_fields_test.exs.
      {:ok, _} = Settings.update_seo_fields_visible(true)

      catalogue = fixture_catalogue(%{name: "Snapshot Catalogue"})

      item =
        fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Snapshot Item", sku: "SNAP-1"})

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))

      refute has_element?(view, "#ext-fake-section")

      fixture_path = Path.expand("../fixtures/item_form_no_ext.html", __DIR__)
      assert normalize(html) == normalize(File.read!(fixture_path))
    end
  end

  describe "with FakeExtension registered" do
    setup do
      start_supervised!(PhoenixKit.ModuleRegistry)
      :ok = ModuleRegistry.register(FakeModule)

      # See the identical on_exit in `PhoenixKitCatalogue.ExtensionsTest` —
      # `start_supervised!`'s teardown has already stopped the registry
      # GenServer by the time this runs, so `unregister/1` (a
      # `GenServer.call`) has nothing to reach; drop `FakeModule` from
      # `:persistent_term` directly (what `all_modules/0` actually reads)
      # so it doesn't survive into later tests' item/category forms.
      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      :ok
    end

    test "the item form renders the extension's section", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))

      assert has_element?(view, "#ext-fake-section")
      assert html =~ ~s(name="item[fake][note]")
    end

    test "saving with a note stores it under item.data[\"fake\"]", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{"name" => "Vase", "fake" => %{"note" => "hi"}}
      })
      |> render_submit()

      saved = Catalogue.get_item!(item.uuid)
      assert saved.data["fake"]["note"] == "hi"
    end

    test "saving without a note shows the error and does not save", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => %{"name" => "Vase", "fake" => %{"note" => ""}}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"

      reloaded = Catalogue.get_item!(item.uuid)
      refute Map.has_key?(reloaded.data, "fake")
    end

    test "the category form renders the extension's section and absorbs a note", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, view, html} = live(conn, edit_category_url(category.uuid))

      assert has_element?(view, "#ext-fake-section")
      assert html =~ ~s(name="category[fake][note]")

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{"name" => "Vases", "fake" => %{"note" => "cat-note"}}
      })
      |> render_submit()

      saved = Catalogue.get_category!(category.uuid)
      assert saved.data["fake"]["note"] == "cat-note"
    end

    test "saving the category without a note shows the error and does not save", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "category" => %{"name" => "Vases", "fake" => %{"note" => ""}}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"

      reloaded = Catalogue.get_category!(category.uuid)
      refute Map.has_key?(reloaded.data, "fake")
    end
  end
end
