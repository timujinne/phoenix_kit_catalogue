defmodule PhoenixKitCatalogue.Web.FormLVBranchesTest do
  @moduledoc """
  Branch coverage for the form LiveViews — exercises every
  `handle_event` clause that isn't already pinned by
  `form_lives_test.exs` (mount + smoke) or `item_form_live_test.exs`
  (item-specific). Targets:

    * Tab + language switching
    * Metadata add/remove
    * Featured-image clear
    * Category move flows (move_category + move_under_parent)
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  describe "inline validation errors actually render" do
    test "clearing the name on the catalogue form shows the error, not silence",
         %{conn: conn} do
      # `to_form/1` drops a changeset's errors entirely when its `action` is
      # nil, so a validate handler that forwards the previous action — which
      # starts nil from mount — renders a form that is invalid and says
      # nothing. The user only learns anything on their first failed save.
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/new")

      html =
        view
        |> form("#catalogue-form", catalogue: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  setup do
    cat = fixture_catalogue(%{name: "Branches Cat"})
    other = fixture_catalogue(%{name: "Other Cat"})
    %{catalogue: cat, other_catalogue: other}
  end

  describe "CatalogueFormLive :edit — tab + language + metadata" do
    test "switch_tab toggles between :details / :metadata / :files",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}/edit")

      render_click(view, "switch_tab", %{"tab" => "metadata"})
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :metadata

      render_click(view, "switch_tab", %{"tab" => "files"})
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :files

      render_click(view, "switch_tab", %{"tab" => "details"})
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :details
    end

    test "switch_language doesn't crash with multilang disabled",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}/edit")
      render_click(view, "switch_language", %{"lang" => "fi"})
      assert Process.alive?(view.pid)
    end

    test "add_meta_field + remove_meta_field round-trip", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}/edit")

      render_click(view, "add_meta_field", %{"key" => "brand"})
      meta = :sys.get_state(view.pid).socket.assigns.meta_state
      assert "brand" in (meta.attached || [])

      render_click(view, "remove_meta_field", %{"key" => "brand"})
      meta = :sys.get_state(view.pid).socket.assigns.meta_state
      refute "brand" in (meta.attached || [])
    end
  end

  describe "CategoryFormLive :edit — language" do
    test "switch_language doesn't crash with multilang disabled",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "C"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      render_click(view, "switch_language", %{"lang" => "fi"})
      assert Process.alive?(view.pid)
    end
  end

  describe "CategoryFormLive — move flows" do
    test "select_move_target sets the candidate catalogue uuid",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "Movable"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-move-form", %{"move_target" => "catalogue:" <> other.uuid})
      |> render_change()

      assert :sys.get_state(view.pid).socket.assigns.move_target == "catalogue:" <> other.uuid
    end

    test "move_category executes the move when target is set",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "ToMove"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-move-form", %{"move_target" => "catalogue:" <> other.uuid})
      |> render_change()

      render_click(view, "move_category", %{})

      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == other.uuid
    end

    test "move_category lands under a category of the other catalogue",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "ToNest"})
      parent = fixture_category(other, %{name: "LandingParent"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-move-form", %{"move_target" => "category:" <> parent.uuid})
      |> render_change()

      render_click(view, "move_category", %{})

      moved = Catalogue.get_category(cat_obj.uuid)
      assert moved.catalogue_uuid == other.uuid
      assert moved.parent_uuid == parent.uuid
    end

    test "the category form's Move section owns its open state on the client",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Owner"})

      # Picking a destination re-renders the page; without this the
      # patch drops the user's `open` and the section folds shut. (The
      # item form moves items through its Location section instead.)
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")
      assert render(element(view, "#category-move-section")) =~ "ignore_attrs"
    end

    test "a destination category deleted after the page opened is refused with a message",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "Mover"})
      landing = fixture_category(other, %{name: "Vanishing landing"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-move-form", %{"move_target" => "category:" <> landing.uuid})
      |> render_change()

      {:ok, _} = Catalogue.permanently_delete_category(landing)
      html = render_click(view, "move_category", %{})

      assert html =~ "Parent category not found."
      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == cat.uuid
    end

    test "a catalogue of the other kind is not offered; unoffered values are ignored",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "Smart elsewhere", kind: "smart"})
      cat_obj = fixture_category(cat, %{name: "Stayer"})
      {:ok, view, html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      assert html =~ "Other Cat — top level" or html =~ "Other Cat &mdash; top level"
      refute html =~ smart.uuid

      render_change(view, "select_move_target", %{"move_target" => "catalogue:" <> smart.uuid})
      assert :sys.get_state(view.pid).socket.assigns.move_target == nil

      render_click(view, "move_category", %{})
      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == cat.uuid
      _ = other
    end

    test "a refused reparent says why", %{conn: conn, catalogue: cat} do
      parent = fixture_category(cat, %{name: "Trashed later"})
      cat_obj = fixture_category(cat, %{name: "Child to be"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-parent-move-form", %{"parent_uuid" => parent.uuid})
      |> render_change()

      {:ok, _} = Catalogue.trash_category(parent)
      html = render_click(view, "move_under_parent", %{})

      assert html =~ "Parent category not found."
    end

    test "the metadata card owns its open state too", %{conn: conn, catalogue: cat} do
      item =
        fixture_item(%{
          catalogue_uuid: cat.uuid,
          name: "With meta",
          data: %{"meta" => %{"brand" => "Acme"}}
        })

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")
      assert render(element(view, "#item-meta-section")) =~ "ignore_attrs"
    end

    test "the parent select reaches the server through its form",
         %{conn: conn, catalogue: cat} do
      parent = fixture_category(cat, %{name: "NewParent"})
      cat_obj = fixture_category(cat, %{name: "Child"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      view
      |> form("#category-parent-move-form", %{"parent_uuid" => parent.uuid})
      |> render_change()

      render_click(view, "move_under_parent", %{})

      assert Catalogue.get_category(cat_obj.uuid).parent_uuid == parent.uuid
    end

    test "move_category with no target is a no-op", %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Untargeted"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      render_click(view, "move_category", %{})

      # Still in the same catalogue — no crash, no move.
      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == cat.uuid
    end

    test "select_parent_move_target sets candidate parent uuid", %{conn: conn, catalogue: cat} do
      parent = fixture_category(cat, %{name: "Parent"})
      child = fixture_category(cat, %{name: "Child"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{child.uuid}/edit")

      render_change(view, "select_parent_move_target", %{"parent_uuid" => parent.uuid})

      assert :sys.get_state(view.pid).socket.assigns.parent_move_target == parent.uuid
    end

    test "a forged non-string parent_uuid is ignored, and Move does not crash",
         %{conn: conn, catalogue: cat} do
      child = fixture_category(cat, %{name: "Child"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{child.uuid}/edit")

      render_change(view, "select_parent_move_target", %{"parent_uuid" => ["x"]})
      assert :sys.get_state(view.pid).socket.assigns.parent_move_target == nil

      render_click(view, "move_under_parent", %{})
      assert Catalogue.get_category(child.uuid).parent_uuid == nil
    end

    test "move_under_parent re-parents under the chosen category",
         %{conn: conn, catalogue: cat} do
      parent = fixture_category(cat, %{name: "NewParent"})
      child = fixture_category(cat, %{name: "OrphanChild"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{child.uuid}/edit")

      render_change(view, "select_parent_move_target", %{"parent_uuid" => parent.uuid})
      render_click(view, "move_under_parent", %{})

      assert Catalogue.get_category(child.uuid).parent_uuid == parent.uuid
    end

    test "select_parent_move_target with empty string clears selection",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Detached"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/categories/#{cat_obj.uuid}/edit")

      render_change(view, "select_parent_move_target", %{"parent_uuid" => ""})

      # No crash; clears the assigns.
      assert :sys.get_state(view.pid).socket.assigns.parent_move_target in [nil, ""]
    end
  end

  describe "ItemFormLive — tab + language + metadata + featured-image clear" do
    setup %{catalogue: cat} do
      item = fixture_item(%{name: "BranchItem", catalogue_uuid: cat.uuid})
      %{item: item}
    end

    test "switch_tab moves between Details / Metadata / Files",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "switch_tab", %{"tab" => "metadata"})
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :metadata

      render_click(view, "switch_tab", %{"tab" => "files"})
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :files
    end

    test "switch_language with multilang disabled is a no-op (no crash)",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")
      # multilang_enabled defaults to false in test env (no PhoenixKit
      # languages settings rows); the handler should still :noreply
      # cleanly without changing current_lang.
      render_click(view, "switch_language", %{"lang" => "fi"})
      assert Process.alive?(view.pid)
    end

    test "clear_featured_image clears the assign", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # Inject a featured image first.
      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns[:featured_image_uuid], Ecto.UUID.generate())
      end)

      render_click(view, "clear_featured_image", %{})
      assert :sys.get_state(view.pid).socket.assigns[:featured_image_uuid] == nil
    end
  end
end
