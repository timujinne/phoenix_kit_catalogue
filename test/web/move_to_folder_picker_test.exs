defmodule PhoenixKitCatalogue.Web.MoveToFolderPickerTest do
  @moduledoc """
  "Move to folder" on the catalogues index picks the folder in a tree, not
  an indented select (boss via Max, 2026-09-21: "no flat lists, only
  proper pickers"). The dialog's form posts what the tree picked.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    {:ok, rooms} = Catalogue.create_folder(%{name: "Rooms"})
    {:ok, inner} = Catalogue.create_folder(%{name: "Inner", parent_uuid: rooms.uuid})
    {:ok, archive} = Catalogue.create_folder(%{name: "Archive"})
    kitchen = fixture_catalogue(%{name: "Kitchen"})

    %{
      conn: with_scope(conn, scope),
      rooms: rooms,
      inner: inner,
      archive: archive,
      kitchen: kitchen
    }
  end

  defp open(view, type, uuid),
    do: render_click(view, "open_move", %{"type" => type, "uuid" => uuid})

  defp pick(view, id),
    do: view |> element(~s(#move-folder-picker [data-place="#{id}"])) |> render_click()

  defp confirm(view), do: view |> form("#move-to-folder-form") |> render_submit()

  test "a catalogue is filed into the folder picked in the tree", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @base)
    open(view, "catalogue", ctx.kitchen.uuid)

    # It is unfiled now: the top level carries the Current badge.
    assert view |> element(~s(#move-folder-picker li[aria-selected="true"])) |> render() =~
             "Current"

    refute has_element?(view, "#move-to-folder-modal select")

    # A folder row picks it; its chevron opens it.
    view
    |> element(
      ~s(#move-folder-picker button[phx-click=toggle][phx-value-id="folder:#{ctx.rooms.uuid}"])
    )
    |> render_click()

    pick(view, "folder:" <> ctx.inner.uuid)
    confirm(view)

    assert Catalogue.get_catalogue(ctx.kitchen.uuid).folder_uuid == ctx.inner.uuid
  end

  test "the top level unfiles it again", %{conn: conn} = ctx do
    {:ok, _} = Catalogue.move_catalogue_to_folder(ctx.kitchen, ctx.archive.uuid)
    {:ok, view, _html} = live(conn, @base)
    open(view, "catalogue", ctx.kitchen.uuid)

    pick(view, "root")
    confirm(view)

    assert Catalogue.get_catalogue(ctx.kitchen.uuid).folder_uuid == nil
  end

  test "confirm acts on the tree's pick, never on a posted folder", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @base)
    open(view, "catalogue", ctx.kitchen.uuid)

    # Nothing picked but where it is: a forged or malformed field moves nothing.
    render_submit(view, "confirm_move", %{"folder_uuid" => ctx.archive.uuid})
    assert Catalogue.get_catalogue(ctx.kitchen.uuid).folder_uuid == nil

    open(view, "catalogue", ctx.kitchen.uuid)
    render_submit(view, "confirm_move", %{"folder_uuid" => "not-a-uuid"})
    assert Process.alive?(view.pid)
    assert Catalogue.get_catalogue(ctx.kitchen.uuid).folder_uuid == nil
  end

  test "filed under a trashed folder, it is at the top level in the tree", %{conn: conn} = ctx do
    {:ok, _} = Catalogue.move_catalogue_to_folder(ctx.kitchen, ctx.archive.uuid)
    {:ok, _} = Catalogue.trash_folder(ctx.archive)
    {:ok, view, _html} = live(conn, @base)
    open(view, "catalogue", ctx.kitchen.uuid)

    assert view |> element(~s(#move-folder-picker li[aria-selected="true"])) |> render() =~
             "Top level"

    # Confirming where it already is moves nothing and says nothing moved.
    html = confirm(view)
    refute html =~ "Catalogue moved."
  end

  test "a folder cannot be picked into its own branch", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @base)
    open(view, "folder", ctx.rooms.uuid)

    html = view |> element("#move-folder-picker") |> render()
    refute html =~ ctx.rooms.uuid
    refute html =~ ctx.inner.uuid

    view
    |> with_target("#move-folder-picker")
    |> render_click("pick", %{"id" => "folder:" <> ctx.inner.uuid})

    pick(view, "folder:" <> ctx.archive.uuid)
    confirm(view)

    assert Catalogue.get_folder(ctx.rooms.uuid).parent_uuid == ctx.archive.uuid
  end
end
