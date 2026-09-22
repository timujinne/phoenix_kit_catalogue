defmodule PhoenixKitCatalogue.Web.ImportPickersTest do
  @moduledoc """
  The import wizard picks its target catalogue and an existing category in
  trees, not flat selects (boss via Max, 2026-09-21: "no flat lists, only
  proper pickers") — catalogues under their folders, categories under
  their parents.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @import_url "/en/admin/catalogue/import"

  setup do
    {:ok, rooms} = Catalogue.create_folder(%{name: "Rooms"})
    kitchen = fixture_catalogue(%{name: "Kitchen"})
    {:ok, kitchen} = Catalogue.move_catalogue_to_folder(kitchen, rooms.uuid)
    doors = fixture_category(kitchen, %{name: "Doors"})

    {:ok, oak} =
      Catalogue.create_category(%{
        name: "Oak",
        catalogue_uuid: kitchen.uuid,
        parent_uuid: doors.uuid
      })

    other = fixture_catalogue(%{name: "Elsewhere"})
    foreign = fixture_category(other, %{name: "Foreign"})
    %{rooms: rooms, kitchen: kitchen, doors: doors, oak: oak, foreign: foreign}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp row(view, picker, id), do: element(view, ~s(##{picker} [data-place="#{id}"]))

  defp toggle(view, picker, id) do
    view
    |> element(~s(##{picker} button[phx-click=toggle][phx-value-id="#{id}"][aria-label]))
    |> render_click()
  end

  defp upload(view, kitchen) do
    file =
      file_input(view, "#upload-form", :import_file, [
        %{
          last_modified: 1_700_000_000_000,
          name: "p.csv",
          content: "name\nHinge\n",
          type: "text/csv"
        }
      ])

    render_upload(file, "p.csv")
    render_submit(view, "parse_file", %{"catalogue" => kitchen.uuid})
  end

  test "the target catalogue is picked under its folder, then folds to its path",
       %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @import_url)

    refute has_element?(view, "#upload-catalogue")
    kitchen = "catalogue:" <> ctx.kitchen.uuid
    refute view |> row("import-catalogue-picker", kitchen) |> has_element?()

    toggle(view, "import-catalogue-picker", "folder:" <> ctx.rooms.uuid)
    # Its counts ride beside its name.
    assert view |> row("import-catalogue-picker", kitchen) |> render() =~ "2 categories"

    view |> row("import-catalogue-picker", kitchen) |> render_click()
    assert assigns(view).selected_catalogue.uuid == ctx.kitchen.uuid
    assert view |> element("#import-catalogue-picker-path") |> render() =~ "Rooms"
    assert view |> element("#import-catalogue-picker-path") |> render() =~ "Kitchen"
    refute has_element?(view, "#import-catalogue-picker-tree")
  end

  test "an existing category is picked in the catalogue's tree and survives the form's changes",
       %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @import_url)
    render_change(view, "validate_upload", %{"catalogue" => ctx.kitchen.uuid})
    upload(view, ctx.kitchen)
    assert assigns(view).step == :map

    html = render_change(view, "select_import_category", %{"category_mode" => "existing"})
    # The categories are no longer options of the mode select.
    refute html =~ ~s(value="existing:#{ctx.oak.uuid}")
    assert has_element?(view, "#import-category-picker")

    toggle(view, "import-category-picker", "category:" <> ctx.doors.uuid)
    view |> row("import-category-picker", "category:" <> ctx.oak.uuid) |> render_click()
    assert assigns(view).import_category_uuid == ctx.oak.uuid

    # The form posts the picker's hidden input with every change.
    render_change(view, "select_import_category", %{
      "category_mode" => "existing",
      "existing_category_uuid" => ctx.oak.uuid,
      "category_match_across_languages" => "true"
    })

    assert assigns(view).import_category_mode == :existing
    assert assigns(view).import_category_uuid == ctx.oak.uuid

    # A category of another catalogue is not taken, by either route.
    render_change(view, "select_import_category", %{
      "category_mode" => "existing",
      "existing_category_uuid" => ctx.foreign.uuid
    })

    assert assigns(view).import_category_uuid == nil

    send(
      view.pid,
      {PhoenixKitCatalogue.Web.Components.PlacePicker, "import-category-picker",
       "category:" <> ctx.foreign.uuid}
    )

    assert assigns(view).import_category_uuid == nil
  end

  test "going back and switching catalogue drops a category picked in the old one",
       %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @import_url)
    render_change(view, "validate_upload", %{"catalogue" => ctx.kitchen.uuid})
    upload(view, ctx.kitchen)

    render_change(view, "select_import_category", %{
      "category_mode" => "existing",
      "existing_category_uuid" => ctx.oak.uuid
    })

    assert assigns(view).import_category_uuid == ctx.oak.uuid

    render_click(view, "go_back", %{})
    other = Catalogue.get_catalogue(ctx.foreign.catalogue_uuid)
    render_submit(view, "parse_file", %{"catalogue" => other.uuid})

    assert assigns(view).step == :map
    assert assigns(view).selected_catalogue.uuid == other.uuid
    assert assigns(view).import_category_mode == :none
    assert assigns(view).import_category_uuid == nil
  end

  test "An existing category with nothing picked does not continue", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @import_url)
    render_change(view, "validate_upload", %{"catalogue" => ctx.kitchen.uuid})
    upload(view, ctx.kitchen)
    render_change(view, "select_import_category", %{"category_mode" => "existing"})

    html = render_click(view, "continue_to_confirm", %{})
    assert html =~ "Pick the category to import into"
    assert assigns(view).step == :map
  end

  test "a catalogue trashed after it was picked is not imported into", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @import_url)
    render_change(view, "validate_upload", %{"catalogue" => ctx.kitchen.uuid})
    upload(view, ctx.kitchen)
    render_click(view, "continue_to_confirm", %{})
    assert assigns(view).step == :confirm

    {:ok, _} = Catalogue.trash_catalogue(ctx.kitchen)
    html = render_click(view, "execute_import", %{})

    assert html =~ "Catalogue not found."
    assert assigns(view).import_task == nil
    refute Enum.any?(Catalogue.list_items_for_catalogue(ctx.kitchen.uuid), &(&1.name == "Hinge"))
  end
end
