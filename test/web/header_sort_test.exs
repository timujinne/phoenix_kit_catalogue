defmodule PhoenixKitCatalogue.Web.HeaderSortTest do
  @moduledoc """
  Column headers sort by a click once the list is out of Manual order, and
  are plain labels in Manual order (boss via Max, 2026-09-21: "when the
  sorting mode isn't in manual, the column headers would have the arrow…
  if it was manual, the arrows wouldn't be there").

  In Manual order a header click would silently leave the order someone
  arranged by hand and take the drag handles with it, so there the sort
  dropdown is the one way out. Every table is driven through its real
  controls and read back.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.Components
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogues"

  setup %{conn: conn, scope: scope} do
    before =
      for s <- [:catalogues, :detail_categories, :detail_items],
          into: %{},
          do: {s, ViewConfig.load_global_sort(s)}

    on_exit(fn -> for {s, {by, dir}} <- before, do: ViewConfig.save_global_sort(s, by, dir) end)

    # Every list starts in Manual order, whatever an earlier test left.
    for s <- Map.keys(before), do: ViewConfig.save_global_sort(s, "position", :asc)

    catalogue = fixture_catalogue(%{name: "Headers"})
    fixture_category(catalogue, %{name: "B cat", position: 0})
    fixture_category(catalogue, %{name: "A cat", position: 1})

    %{conn: with_scope(conn, scope), catalogue: catalogue}
  end

  test "header_sort/2: nil in Manual order, the sort otherwise" do
    assert Components.header_sort(:position, :asc) == nil
    assert Components.header_sort("position", :desc) == nil
    assert Components.header_sort(:name, :desc) == %{by: :name, dir: :desc}
    assert Components.header_sort("updated", :asc) == %{by: "updated", dir: :asc}
  end

  describe "a catalogue's categories" do
    @header ~s(#catalogue-categories-tree th button[phx-click="toggle_sort_categories"])

    test "no header sorts in Manual order", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      refute has_element?(view, @header)
    end

    test "out of Manual order the headers sort, and a click re-sorts", %{
      conn: conn,
      catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      view |> element("#categories-sort-selector") |> render_change(%{"sort_by" => "updated"})

      assert has_element?(view, ~s(#{@header}[phx-value-by="name"]))

      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :asc}

      # The same header again flips the direction.
      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :desc}
    end

    test "a pushed header click naming Manual order is ignored", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      view |> element("#categories-sort-selector") |> render_change(%{"sort_by" => "name"})

      render_click(view, "toggle_sort_categories", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :asc}
    end
  end

  describe "a catalogue's items" do
    setup %{catalogue: c} do
      # An item-only level puts the items list on the page.
      bare = fixture_catalogue(%{name: "Items only"})
      fixture_item(%{catalogue_uuid: bare.uuid, name: "Hinge", sku: "H-1"})
      fixture_item(%{catalogue_uuid: bare.uuid, name: "Door", sku: "D-1"})
      %{items_catalogue: bare, catalogue: c}
    end

    @header ~s(th button[phx-click="toggle_sort_items"])

    test "no header sorts in Manual order; out of it they do", %{
      conn: conn,
      items_catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      refute has_element?(view, @header)

      render_change(view, "sort_items", %{"sort_by" => "name"})
      assert has_element?(view, ~s(#{@header}[phx-value-by="sku"]))

      view |> element(~s(#{@header}[phx-value-by="sku"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_items) == {"sku", :asc}
    end

    test "a pushed header click naming Manual order is ignored", %{
      conn: conn,
      items_catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_change(view, "sort_items", %{"sort_by" => "name"})

      render_click(view, "toggle_sort_items", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:detail_items) == {"name", :asc}
    end
  end

  describe "the catalogues index" do
    @header ~s(th button[phx-click="toggle_sort"])

    test "no header sorts in Manual order; out of it they do", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)
      refute has_element?(view, @header)

      render_change(view, "set_sort", %{"sort_by" => "name"})
      assert has_element?(view, ~s(#{@header}[phx-value-by="name"]))

      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:catalogues) == {"name", :desc}
    end

    test "a pushed header click naming Manual order is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)
      render_change(view, "set_sort", %{"sort_by" => "name"})

      render_click(view, "toggle_sort", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:catalogues) == {"name", :asc}
    end
  end

  # Core keeps every changed setting value as a permanent activity entry,
  # and the shared sort is a setting — so a click must write once, name who
  # clicked, and write nothing when it changes nothing.
  describe "the shared sort in the settings history" do
    alias PhoenixKitCatalogue.Catalogue.PubSub

    # Entries written by a person; the setup's own resets carry no actor.
    defp sort_entries(scope_key) do
      Enum.filter(
        list_activities(),
        &(&1.action == "setting.changed" and &1.actor_uuid != nil and
            &1.metadata["key"] == "catalogue_sort_" <> scope_key)
      )
    end

    defp all_sort_entries(scope_key) do
      Enum.filter(
        list_activities(),
        &(&1.action == "setting.changed" and
            &1.metadata["key"] == "catalogue_sort_" <> scope_key)
      )
    end

    test "save_global_sort/4 writes nothing when the sort is already stored" do
      assert {:ok, :unchanged} = ViewConfig.save_global_sort(:detail_items, "position", :asc)
      before = length(all_sort_entries("detail_items"))

      assert {:ok, %{value: "name:desc"}} =
               ViewConfig.save_global_sort(:detail_items, "name", :desc)

      assert {:ok, :unchanged} = ViewConfig.save_global_sort(:detail_items, "name", :desc)
      assert length(all_sort_entries("detail_items")) == before + 1
    end

    test "a header click on the index is attributed to the admin, once", %{
      conn: conn,
      scope: scope
    } do
      PubSub.subscribe()
      {:ok, view, _html} = live(conn, @base)

      render_change(view, "set_sort", %{"sort_by" => "name"})

      assert [entry] = sort_entries("catalogues")
      assert entry.actor_uuid == Ecto.UUID.dump!(scope.user.uuid)
      assert entry.mode == "manual"
      assert entry.metadata["source"] == "settings"
      assert entry.metadata["to"] == "name:asc"
      assert_receive {:catalogue_view_sort_changed, :catalogues, "name", :asc, _from}

      # Choosing the sort the list already has changes nothing to record.
      render_change(view, "set_sort", %{"sort_by" => "name"})
      assert [_only] = sort_entries("catalogues")
    end

    test "the detail page's item and category sorts are attributed too", %{
      conn: conn,
      scope: scope,
      catalogue: catalogue
    } do
      PubSub.subscribe()
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")

      view |> element("#categories-sort-selector") |> render_change(%{"sort_by" => "name"})
      render_change(view, "sort_items", %{"sort_by" => "name"})

      for scope_key <- ["detail_categories", "detail_items"] do
        assert [entry] = sort_entries(scope_key)
        assert entry.actor_uuid == Ecto.UUID.dump!(scope.user.uuid)
        assert entry.metadata["source"] == "settings"
      end

      assert_receive {:catalogue_view_sort_changed, :detail_categories, "name", :asc, _}
      assert_receive {:catalogue_view_sort_changed, :detail_items, "name", :asc, _}
    end
  end

  describe "a sort broadcast that arrives after a later one was stored" do
    # Two admins commit different sorts; the earlier writer's broadcast is
    # delivered last. The stored sort is the later one, and every page must
    # end on it.
    defp first_before?(html, first, second) do
      {a, _} = :binary.match(html, first)
      {b, _} = :binary.match(html, second)
      a < b
    end

    test "the index ends on the stored sort", %{conn: conn} do
      fixture_catalogue(%{name: "Stale Aaa"})
      fixture_catalogue(%{name: "Stale Zzz"})
      {:ok, view, _html} = live(conn, @base)
      other_admin = spawn(fn -> :ok end)

      {:ok, _} = ViewConfig.save_global_sort(:catalogues, "name", :desc)
      send(view.pid, {:catalogue_view_sort_changed, :catalogues, "name", :asc, other_admin})

      assert first_before?(render(view), "Stale Zzz", "Stale Aaa")
      assert :sys.get_state(view.pid).socket.assigns.view_configs.catalogues.sort_dir == :desc
    end

    test "the detail page's categories end on the stored sort", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      other_admin = spawn(fn -> :ok end)

      {:ok, _} = ViewConfig.save_global_sort(:detail_categories, "name", :desc)

      send(
        view.pid,
        {:catalogue_view_sort_changed, :detail_categories, "name", :asc, other_admin}
      )

      html = view |> element("#catalogue-categories-tree") |> render()
      assert first_before?(html, "B cat", "A cat")
      assert :sys.get_state(view.pid).socket.assigns.categories_sort_dir == :desc
    end

    test "the detail page's items end on the stored sort", %{conn: conn} do
      # An item-only level puts the items list on the page.
      c = fixture_catalogue(%{name: "Stale items"})
      fixture_item(%{name: "Stale item Aaa", catalogue_uuid: c.uuid})
      fixture_item(%{name: "Stale item Zzz", catalogue_uuid: c.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      other_admin = spawn(fn -> :ok end)

      {:ok, _} = ViewConfig.save_global_sort(:detail_items, "name", :desc)
      send(view.pid, {:catalogue_view_sort_changed, :detail_items, "name", :asc, other_admin})

      assert first_before?(render(view), "Stale item Zzz", "Stale item Aaa")
      assert :sys.get_state(view.pid).socket.assigns.items_sort_dir == :desc
    end
  end
end
