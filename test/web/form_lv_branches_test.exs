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
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo
  alias PhoenixKitCatalogue.Web.PlaceTree

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
    # One Move, picked in a tree of every catalogue of the category's kind
    # (boss via Max, 2026-09-21: proper pickers, no flat lists): a place in
    # its own catalogue reparents, a place in another moves it there.
    defp edit(conn, category),
      do: live(conn, "/en/admin/catalogue/categories/#{category.uuid}/edit")

    defp pick(view, place, name) do
      view |> element("#category-move-picker-change") |> render_click()

      view
      |> element("#category-move-picker-search")
      |> render_hook("search", %{"value" => name})

      view |> element(~s(#category-move-picker [data-place="#{place}"])) |> render_click()
    end

    defp move(view), do: view |> element("#category-move-button") |> render_click()

    test "a category of another catalogue: it moves there, under it",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "ToNest"})
      landing = fixture_category(other, %{name: "LandingParent"})
      {:ok, view, _html} = edit(conn, cat_obj)

      pick(view, "category:" <> landing.uuid, "LandingParent")
      assert {:error, {:live_redirect, _}} = move(view)

      moved = Catalogue.get_category(cat_obj.uuid)
      assert moved.catalogue_uuid == other.uuid
      assert moved.parent_uuid == landing.uuid
    end

    test "another catalogue's own row: its top level",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "ToMove"})
      {:ok, view, _html} = edit(conn, cat_obj)

      pick(view, "catalogue:" <> other.uuid, "Other Cat")
      move(view)

      moved = Catalogue.get_category(cat_obj.uuid)
      assert moved.catalogue_uuid == other.uuid
      assert moved.parent_uuid == nil
    end

    test "a category of its own catalogue reparents, and the own row goes back to the top",
         %{conn: conn, catalogue: cat} do
      parent = fixture_category(cat, %{name: "NewParent"})
      child = fixture_category(cat, %{name: "OrphanChild"})
      {:ok, view, _html} = edit(conn, child)

      pick(view, "category:" <> parent.uuid, "NewParent")
      html = move(view)
      assert html =~ "Category moved into NewParent."
      assert Catalogue.get_category(child.uuid).parent_uuid == parent.uuid

      pick(view, "catalogue:" <> cat.uuid, "Branches Cat")
      move(view)
      assert Catalogue.get_category(child.uuid).parent_uuid == nil
    end

    test "its own subtree and catalogues of the other kind are not offered",
         %{conn: conn, catalogue: cat} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "Smart elsewhere", kind: "smart"})
      cat_obj = fixture_category(cat, %{name: "Stayer"})

      {:ok, grandchild_parent} =
        Catalogue.create_category(%{
          name: "Below",
          catalogue_uuid: cat.uuid,
          parent_uuid: cat_obj.uuid
        })

      {:ok, view, _html} = edit(conn, cat_obj)
      view |> element("#category-move-picker-change") |> render_click()
      html = view |> element("#category-move-picker") |> render()

      assert html =~ ~s(data-place="catalogue:#{cat.uuid}")
      refute html =~ smart.uuid
      refute html =~ ~s(data-place="category:#{cat_obj.uuid}")

      # Forged picks of what the tree left out never become the target.
      for id <- ["category:" <> grandchild_parent.uuid, "catalogue:" <> smart.uuid] do
        view |> with_target("#category-move-picker") |> render_click("pick", %{"id" => id})
      end

      assert :sys.get_state(view.pid).socket.assigns.move_target == nil
      assert has_element?(view, "#category-move-button[disabled]")
      render_click(view, "move_category", %{})
      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == cat.uuid
    end

    # A › B (trashed) › C (restored on its own): the live tree shows C at
    # the top level, yet it is still in A's subtree, so moving A there
    # would be a cycle the context refuses.
    test "a live category below a trashed one of its subtree is not offered",
         %{conn: conn, catalogue: cat} do
      a = fixture_category(cat, %{name: "Top A"})

      {:ok, b} =
        Catalogue.create_category(%{name: "Mid B", catalogue_uuid: cat.uuid, parent_uuid: a.uuid})

      {:ok, c} =
        Catalogue.create_category(%{name: "Low C", catalogue_uuid: cat.uuid, parent_uuid: b.uuid})

      {:ok, _} = Catalogue.trash_category(b)
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(c.uuid))
      assert %{status: "active", parent_uuid: parent} = Catalogue.get_category(c.uuid)
      assert parent == b.uuid

      {:ok, view, _html} = edit(conn, a)
      tree = :sys.get_state(view.pid).socket.assigns.move_tree

      assert PlaceTree.find(tree, "catalogue:" <> cat.uuid)
      refute PlaceTree.find(tree, "category:" <> c.uuid)
    end

    test "Move waits for a pick, and picking where it is takes the pick back",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      cat_obj = fixture_category(cat, %{name: "Untargeted"})
      {:ok, view, _html} = edit(conn, cat_obj)

      assert has_element?(view, "#category-move-button[disabled]")
      render_click(view, "move_category", %{})
      assert Catalogue.get_category(cat_obj.uuid).catalogue_uuid == cat.uuid

      pick(view, "catalogue:" <> other.uuid, "Other Cat")
      refute has_element?(view, "#category-move-button[disabled]")
      pick(view, "catalogue:" <> cat.uuid, "Branches Cat")
      assert has_element?(view, "#category-move-button[disabled]")
    end

    test "a destination removed after it was picked is refused with a message",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      mover = fixture_category(cat, %{name: "Mover"})
      landing = fixture_category(other, %{name: "Vanishing landing"})
      {:ok, view, _html} = edit(conn, mover)

      # Removed by someone else before their change reached this page (a
      # write with no broadcast; the broadcast would drop the pick at once).
      pick(view, "category:" <> landing.uuid, "Vanishing")
      {:ok, _} = TestRepo.delete(landing)

      assert move(view) =~ "Parent category not found."
      assert Catalogue.get_category(mover.uuid).catalogue_uuid == cat.uuid

      parent = fixture_category(cat, %{name: "Trashed later"})
      pick(view, "category:" <> parent.uuid, "Trashed later")
      {:ok, _} = parent |> Ecto.Changeset.change(status: "deleted") |> TestRepo.update()

      assert move(view) =~ "Parent category not found."
      assert Catalogue.get_category(mover.uuid).parent_uuid == nil
    end

    test "the branch is read from where the category is now, not where the page found it",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      home = fixture_category(cat, %{name: "Home"})

      {:ok, cat_obj} =
        Catalogue.create_category(%{
          name: "Wanderer",
          catalogue_uuid: cat.uuid,
          parent_uuid: home.uuid
        })

      {:ok, view, _html} = edit(conn, cat_obj)

      # Someone else moves it to the other catalogue; the admin then picks
      # the top level of the catalogue the page first showed it in.
      {:ok, _} = Catalogue.move_category_to_catalogue(cat_obj, other.uuid)
      pick(view, "catalogue:" <> cat.uuid, "Branches Cat")
      move(view)

      moved = Catalogue.get_category(cat_obj.uuid)
      assert moved.catalogue_uuid == cat.uuid
      assert moved.parent_uuid == nil
    end

    test "a pick the refreshed tree lost is dropped", %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Stays"})
      landing = fixture_category(cat, %{name: "Going away"})
      {:ok, view, _html} = edit(conn, cat_obj)

      pick(view, "category:" <> landing.uuid, "Going away")
      assert :sys.get_state(view.pid).socket.assigns.move_target

      {:ok, _} = Catalogue.trash_category(landing)
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.move_target == nil
      assert has_element?(view, "#category-move-button[disabled]")
    end

    test "the category form's Move section owns its open state on the client",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Owner"})

      # Picking a destination re-renders the page; without this the
      # patch drops the user's `open` and the section folds shut.
      {:ok, view, _html} = edit(conn, cat_obj)
      assert render(element(view, "#category-move-section")) =~ "ignore_attrs"
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
  end

  describe "CategoryFormLive :new — parent picked in the tree" do
    # A `?parent_uuid=` the tree does not offer (trashed since the link was
    # rendered, another catalogue's, not a UUID) used to stay picked with
    # no row to show it: the hidden input posted it and Save failed on a
    # field the form renders no error for.
    test "a parent in the URL the tree does not offer starts at the top level, and saves",
         %{conn: conn, catalogue: cat, other_catalogue: other} do
      trashed = fixture_category(cat, %{name: "Gone"})
      {:ok, _} = Catalogue.trash_category(trashed)
      foreign = fixture_category(other, %{name: "Elsewhere"})

      for {parent, name} <- [
            {trashed.uuid, "After trash"},
            {foreign.uuid, "After foreign"},
            {"nope", "After junk"}
          ] do
        {:ok, view, _html} =
          live(conn, "/en/admin/catalogue/#{cat.uuid}/categories/new?parent_uuid=#{parent}")

        assert :sys.get_state(view.pid).socket.assigns.parent_pick == "root"

        view
        |> form("#category-form", %{"category" => %{"name" => name}})
        |> render_submit()

        assert [%{parent_uuid: nil}] =
                 Enum.filter(Catalogue.list_live_categories([cat.uuid]), &(&1.name == name))
      end
    end

    test "its catalogue deleted forever while the form is open does not crash it",
         %{conn: conn} do
      doomed = fixture_catalogue(%{name: "Doomed"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{doomed.uuid}/categories/new")

      {:ok, _} = Catalogue.permanently_delete_catalogue(doomed)
      _ = render(view)

      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.parent_tree == []
    end

    test "a parent trashed after it was picked is dropped, and the context refuses it",
         %{conn: conn, catalogue: cat} do
      doors = fixture_category(cat, %{name: "Doors"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}/categories/new")

      view |> element("#category-parent-picker-change") |> render_click()

      view
      |> element(~s(#category-parent-picker [data-place="category:#{doors.uuid}"]))
      |> render_click()

      {:ok, _} = Catalogue.trash_category(doors)
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.parent_pick == "root"

      # Whatever the form posts, a trashed parent is never taken.
      assert {:error, changeset} =
               Catalogue.create_category(%{
                 name: "Under the trash",
                 catalogue_uuid: cat.uuid,
                 parent_uuid: doors.uuid
               })

      assert changeset.errors[:parent_uuid]
    end

    test "it starts at the top level, and saves under the category picked",
         %{conn: conn, catalogue: cat} do
      doors = fixture_category(cat, %{name: "Doors"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}/categories/new")

      assert view |> element("#category-parent-picker-path") |> render() =~ "Branches Cat"

      view |> element("#category-parent-picker-change") |> render_click()

      view
      |> element(~s(#category-parent-picker [data-place="category:#{doors.uuid}"]))
      |> render_click()

      assert view |> element("#category-parent-picker-path") |> render() =~ "Doors"

      view
      |> form("#category-form", %{"category" => %{"name" => "Oak"}})
      |> render_submit()

      assert [%{parent_uuid: parent}] =
               Enum.filter(Catalogue.list_live_categories([cat.uuid]), &(&1.name == "Oak"))

      assert parent == doors.uuid
    end

    test "a parent in the URL starts picked; the catalogue's own row means top level",
         %{conn: conn, catalogue: cat} do
      doors = fixture_category(cat, %{name: "Doors"})

      {:ok, view, _html} =
        live(conn, "/en/admin/catalogue/#{cat.uuid}/categories/new?parent_uuid=#{doors.uuid}")

      assert view |> element("#category-parent-picker-path") |> render() =~ "Doors"

      view |> element("#category-parent-picker-change") |> render_click()
      view |> element(~s(#category-parent-picker [data-place="root"])) |> render_click()

      view
      |> form("#category-form", %{"category" => %{"name" => "Top one"}})
      |> render_submit()

      assert [%{parent_uuid: nil}] =
               Enum.filter(Catalogue.list_live_categories([cat.uuid]), &(&1.name == "Top one"))
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
