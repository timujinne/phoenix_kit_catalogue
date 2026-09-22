defmodule PhoenixKitCatalogue.Web.NewFolderNameTest do
  @moduledoc """
  New folders get distinct names (boss via Max, 2026-09-21: "it's just the
  same name over and over, not like new folder one, new folder two").
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    %{conn: with_scope(conn, scope)}
  end

  defp names(parent_uuid) do
    Catalogue.list_folder_tree()
    |> Enum.map(fn {folder, _depth} -> folder end)
    |> Enum.filter(&(&1.parent_uuid == parent_uuid))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  test "each New folder at the top level takes the next free name", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)

    for _ <- 1..3, do: render_click(view, "new_folder", %{})

    assert names(nil) == ["New folder", "New folder 2", "New folder 3"]
  end

  test "a gap is filled before counting on", %{conn: conn} do
    {:ok, _} = Catalogue.create_folder(%{name: "New folder"})
    {:ok, _} = Catalogue.create_folder(%{name: "New folder 3"})

    {:ok, view, _html} = live(conn, @base)
    render_click(view, "new_folder", %{})

    assert "New folder 2" in names(nil)
  end

  test "numbering is per folder: a subfolder starts from the plain name again", %{conn: conn} do
    {:ok, parent} = Catalogue.create_folder(%{name: "New folder"})

    {:ok, view, _html} = live(conn, @base)
    render_click(view, "new_subfolder", %{"uuid" => parent.uuid})
    render_click(view, "new_subfolder", %{"uuid" => parent.uuid})

    assert names(parent.uuid) == ["New folder", "New folder 2"]
  end
end
