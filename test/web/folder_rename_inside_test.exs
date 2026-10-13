defmodule PhoenixKitCatalogue.Web.FolderRenameInsideTest do
  @moduledoc """
  A folder can be renamed from inside it (boss via Max, 2026-09-21: "you
  can't rename a folder from inside a folder — you have to go back out and
  use the three dots"). The folder you stand in has no row of its own on
  screen, so the location row carries the rename.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  @base "/en/admin/catalogues"

  setup %{conn: conn, scope: scope} do
    {:ok, folder} = Catalogue.create_folder(%{name: "Old name"})
    %{conn: with_scope(conn, scope), folder: folder}
  end

  defp inside(conn, folder) do
    {:ok, view, _html} = live(conn, @base)
    render_click(view, "navigate_folder", %{"uuid" => folder.uuid})
    view
  end

  test "the pencil turns the name into a field, and Enter saves", %{conn: conn, folder: folder} do
    view = inside(conn, folder)

    view |> element("#location-rename-button") |> render_click()
    assert has_element?(view, "#location-rename-#{folder.uuid} input[name=name]")

    view
    |> form("#location-rename-#{folder.uuid}", %{"name" => "New name"})
    |> render_submit()

    assert Catalogue.get_folder(folder.uuid).name == "New name"
    # Still inside the folder, showing the new name, field closed.
    assert has_element?(view, "#location-rename-button")
    assert render(view) =~ "New name"
  end

  test "clicking away saves too; a blank name keeps the old one", %{conn: conn, folder: folder} do
    view = inside(conn, folder)
    view |> element("#location-rename-button") |> render_click()

    view
    |> element("#location-rename-#{folder.uuid} input")
    |> render_blur(%{"value" => "   "})

    assert Catalogue.get_folder(folder.uuid).name == "Old name"

    view |> element("#location-rename-button") |> render_click()

    view
    |> element("#location-rename-#{folder.uuid} input")
    |> render_blur(%{"value" => "Blurred name"})

    assert Catalogue.get_folder(folder.uuid).name == "Blurred name"
  end

  test "the blur that follows Enter writes nothing more", %{conn: conn, folder: folder} do
    # Enter closes the field; removing the focused input can then fire its
    # phx-blur with whatever the input last held. It must not rename again.
    view = inside(conn, folder)
    view |> element("#location-rename-button") |> render_click()

    view
    |> form("#location-rename-#{folder.uuid}", %{"name" => "New name"})
    |> render_submit()

    render_blur(view, "rename_folder", %{"uuid" => folder.uuid, "value" => "New na"})

    assert Catalogue.get_folder(folder.uuid).name == "New name"
  end

  test "a folder removed while its field was open is not renamed", %{conn: conn, folder: folder} do
    view = inside(conn, folder)
    view |> element("#location-rename-button") |> render_click()

    # Removed by someone else before their change reached this page: a
    # write with no broadcast is that window (the broadcast would reload
    # the page and take the field away).
    {:ok, _} = folder |> Ecto.Changeset.change(status: "deleted") |> TestRepo.update()

    view
    |> form("#location-rename-#{folder.uuid}", %{"name" => "Too late"})
    |> render_submit()

    assert Catalogue.get_folder(folder.uuid).name == "Old name"
  end

  test "at the top level there is no location row to rename", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)
    refute has_element?(view, "#location-rename-button")
  end

  describe "a name the folder cannot take" do
    @too_long String.duplicate("n", 256)

    test "Enter leaves the field open on what was typed, and says why", %{
      conn: conn,
      folder: folder
    } do
      view = inside(conn, folder)
      view |> element("#location-rename-button") |> render_click()

      html =
        view
        |> form("#location-rename-#{folder.uuid}", %{"name" => @too_long})
        |> render_submit()

      assert html =~ "That name is too long: 255 characters at most."
      assert Catalogue.get_folder(folder.uuid).name == "Old name"

      assert has_element?(
               view,
               ~s(#location-rename-#{folder.uuid} input[name="name"][value="#{@too_long}"])
             )

      # Corrected in the same field, it saves and the field closes.
      view |> form("#location-rename-#{folder.uuid}", %{"name" => "Short"}) |> render_submit()

      assert Catalogue.get_folder(folder.uuid).name == "Short"
      refute has_element?(view, "#location-rename-#{folder.uuid}")
    end

    test "clicking away does the same", %{conn: conn, folder: folder} do
      view = inside(conn, folder)
      view |> element("#location-rename-button") |> render_click()

      html =
        view
        |> element("#location-rename-#{folder.uuid} input")
        |> render_blur(%{"value" => @too_long})

      assert html =~ "That name is too long: 255 characters at most."
      assert has_element?(view, ~s(#location-rename-#{folder.uuid} input[value="#{@too_long}"]))
    end

    test "Escape closes the field and forgets what was typed", %{conn: conn, folder: folder} do
      view = inside(conn, folder)
      view |> element("#location-rename-button") |> render_click()
      view |> form("#location-rename-#{folder.uuid}", %{"name" => @too_long}) |> render_submit()

      view
      |> element("#location-rename-#{folder.uuid} input")
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#location-rename-#{folder.uuid}")

      view |> element("#location-rename-button") |> render_click()
      assert has_element?(view, ~s(#location-rename-#{folder.uuid} input[value="Old name"]))
    end

    # The same field is drawn in the tree and on a folder's card.
    test "every rename field stops typing at the limit", %{conn: conn, folder: folder} do
      {:ok, child} = Catalogue.create_folder(%{name: "Child", parent_uuid: folder.uuid})

      view = inside(conn, folder)
      render_click(view, "start_rename_folder", %{"uuid" => child.uuid})
      assert has_element?(view, ~s(form[phx-submit="rename_folder"] input[maxlength="255"]))

      html =
        render_submit(view, "rename_folder", %{"uuid" => child.uuid, "name" => @too_long})

      assert html =~ "That name is too long"
      assert has_element?(view, ~s(form[phx-submit="rename_folder"] input[value="#{@too_long}"]))
      assert Catalogue.get_folder(child.uuid).name == "Child"

      view |> element("#location-rename-button") |> render_click()
      assert has_element?(view, ~s(#location-rename-#{folder.uuid} input[maxlength="255"]))
    end
  end
end
