defmodule PhoenixKitCatalogue.Web.PlacePickerTest do
  @moduledoc """
  The tree picker every place choice uses (the owner, via Max, 2026-09-21:
  no flat lists, only proper pickers): `Web.PlaceTree` builds the trees,
  `Components.PlacePicker` shows one.

  The component is hosted inside a form with its own `phx-change` and
  `phx-submit`, the placement the category form gives it — what the host
  receives is recorded and read back.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Components.PlacePicker
  alias PhoenixKitCatalogue.Web.PlaceTree

  defmodule Host do
    use Phoenix.LiveView

    # Nested here, it inherits the case's imports (Plug.Conn has an assign/3 too).

    def mount(_params, session, socket) do
      {:ok,
       Phoenix.Component.assign(socket,
         tree: session["tree"],
         value: session["value"],
         opts: session["opts"] || %{},
         picked: [],
         changes: [],
         submitted: nil
       )}
    end

    def render(assigns) do
      ~H"""
      <form id="host-form" phx-change="validate" phx-submit="save">
        <input type="text" name="title" value="kept" />
        <.live_component
          module={PlacePicker}
          id="pp"
          tree={@tree}
          value={@value}
          name="place"
          {@opts}
        />
      </form>
      """
    end

    def handle_info({PlacePicker, "pp", value}, socket),
      do:
        {:noreply,
         Phoenix.Component.assign(socket, value: value, picked: socket.assigns.picked ++ [value])}

    def handle_event("validate", params, socket),
      do:
        {:noreply, Phoenix.Component.assign(socket, :changes, socket.assigns.changes ++ [params])}

    def handle_event("save", params, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :submitted, params)}
  end

  defp host(conn, tree, value \\ nil, opts \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"tree" => tree, "value" => value, "opts" => opts})

    view
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns

  defp search(view, text),
    do: view |> element("#pp-search") |> render_hook("search", %{"value" => text})

  defp row(view, id), do: element(view, ~s(#pp [data-place="#{id}"]))

  # Kitchen (standard, in folder Rooms) › Doors › Oak; Hardware (smart).
  setup do
    {:ok, rooms} = Catalogue.create_folder(%{name: "Rooms"})
    {:ok, empty} = Catalogue.create_folder(%{name: "Empty"})
    kitchen = fixture_catalogue(%{name: "Kitchen"})
    {:ok, kitchen} = Catalogue.move_catalogue_to_folder(kitchen, rooms.uuid)
    hardware = fixture_catalogue(%{name: "Hardware", kind: "smart"})
    doors = fixture_category(kitchen, %{name: "Doors"})

    {:ok, oak} =
      Catalogue.create_category(%{
        name: "Oak",
        catalogue_uuid: kitchen.uuid,
        parent_uuid: doors.uuid
      })

    %{rooms: rooms, empty: empty, kitchen: kitchen, hardware: hardware, doors: doors, oak: oak}
  end

  describe "PlaceTree builders" do
    test "places/2 nests folders › catalogues › categories, by kind", ctx do
      tree = PlaceTree.places("standard")

      assert [%{id: "folder:" <> _, name: "Rooms", children: [kitchen]}] =
               Enum.filter(tree, &(&1.type == :folder))

      assert kitchen.id == "catalogue:" <> ctx.kitchen.uuid
      assert [%{name: "Doors", children: [%{name: "Oak", children: []}]}] = kitchen.children
      # The smart catalogue is another kind; the empty folder leads nowhere.
      refute PlaceTree.find(tree, "catalogue:" <> ctx.hardware.uuid)
      refute PlaceTree.find(tree, "folder:" <> ctx.empty.uuid)

      assert PlaceTree.find(PlaceTree.places(nil), "catalogue:" <> ctx.hardware.uuid)

      assert [] =
               PlaceTree.places("standard", categories: false)
               |> hd()
               |> then(& &1.children)
               |> hd()
               |> then(& &1.children)
    end

    test "categories/2 hangs them under the catalogue's own row when asked", ctx do
      assert [%{name: "Doors"}] = PlaceTree.categories(ctx.kitchen)

      assert [%{id: "root", type: :root, name: "Kitchen", hint: "top level"} = root] =
               PlaceTree.categories(ctx.kitchen, root: "top level")

      assert [%{name: "Doors"}] = root.children
    end

    test "folders/1 puts every folder under the root row", ctx do
      assert [%{id: "root", type: :root, name: "Top level", children: children}] =
               PlaceTree.folders("Top level")

      assert Enum.map(children, & &1.id) |> Enum.sort() ==
               Enum.sort(["folder:" <> ctx.rooms.uuid, "folder:" <> ctx.empty.uuid])
    end

    test "prune, path_in, member?, ids_of and uuid", ctx do
      tree = PlaceTree.places("standard")
      oak = "category:" <> ctx.oak.uuid

      assert PlaceTree.path_in(tree, oak, [:folder]) == ["Kitchen", "Doors", "Oak"]
      assert PlaceTree.path_in(tree, oak) == ["Rooms", "Kitchen", "Doors", "Oak"]
      assert PlaceTree.member?(tree, oak, [:category])
      refute PlaceTree.member?(tree, oak, [:catalogue])
      refute PlaceTree.member?(tree, "category:nope", [:category])

      pruned = PlaceTree.prune(tree, ["category:" <> ctx.doors.uuid])
      refute PlaceTree.find(pruned, oak)
      assert PlaceTree.find(pruned, "catalogue:" <> ctx.kitchen.uuid)

      assert PlaceTree.ids_of(tree, [:catalogue]) == ["catalogue:" <> ctx.kitchen.uuid]
      assert PlaceTree.uuid(oak) == ctx.oak.uuid
      assert PlaceTree.uuid("root") == nil
    end

    test "filter/2 ignores case and accents and opens the rows above a match", ctx do
      {:ok, _} = Catalogue.update_category(ctx.oak, %{name: "Öak veneer"})
      tree = PlaceTree.places("standard")

      {shown, open} = PlaceTree.filter(tree, "oak ven")
      assert PlaceTree.path_in(shown, "category:" <> ctx.oak.uuid, [:folder]) != []
      assert ("category:" <> ctx.doors.uuid) in open
      assert {^tree, []} = PlaceTree.filter(tree, "  ")
    end
  end

  describe "PlacePicker" do
    test "opens at the picked place and posts its uuid with the host form", %{conn: conn} = ctx do
      oak = "category:" <> ctx.oak.uuid
      view = host(conn, PlaceTree.places("standard"), oak)

      assert view |> row(oak) |> has_element?()
      assert has_element?(view, ~s(#pp li[aria-selected="true"] [data-place="#{oak}"]))

      view |> form("#host-form") |> render_submit()
      assert state(view).submitted["place"] == ctx.oak.uuid
      assert state(view).submitted["title"] == "kept"
    end

    test "picking a row tells the host; a folder row only opens", %{conn: conn} = ctx do
      view = host(conn, PlaceTree.places("standard"))
      folder = "folder:" <> ctx.rooms.uuid
      kitchen = "catalogue:" <> ctx.kitchen.uuid

      refute has_element?(view, ~s(#pp [data-place="#{kitchen}"]))
      view |> row(folder) |> render_click()
      assert state(view).picked == []
      assert has_element?(view, ~s(#pp [data-place="#{kitchen}"]))

      view |> row(kitchen) |> render_click()
      assert state(view).picked == [kitchen]

      assert view |> element(~s(#pp input[type=hidden][name=place])) |> render() =~
               ctx.kitchen.uuid
    end

    test "a forged pick outside the tree or of an unpickable type is ignored",
         %{conn: conn} = ctx do
      view = host(conn, PlaceTree.places("standard"), nil, %{pickable: [:category]})

      view
      |> with_target("#pp")
      |> render_click("pick", %{"id" => "category:" <> Ecto.UUID.generate()})

      view
      |> with_target("#pp")
      |> render_click("pick", %{"id" => "catalogue:" <> ctx.kitchen.uuid})

      assert state(view).picked == []
    end

    test "search narrows the tree and opens the way to each match", %{conn: conn} = ctx do
      view = host(conn, PlaceTree.places("standard"))

      html = search(view, "oak")
      assert html =~ ~s(data-place="category:#{ctx.oak.uuid}")
      refute html =~ ~s(data-place="folder:#{ctx.empty.uuid}")

      assert search(view, "zzz") =~ "No matches."
      html = search(view, "")
      assert html =~ ~s(data-place="folder:#{ctx.rooms.uuid}")
      refute html =~ ~s(data-place="category:#{ctx.oak.uuid}")
    end

    test "a pushed pick_all on a single picker changes nothing", %{conn: conn} = ctx do
      view = host(conn, PlaceTree.places("standard"))

      view
      |> with_target("#pp")
      |> render_click("pick_all", %{"id" => "folder:" <> ctx.rooms.uuid})

      assert Process.alive?(view.pid)
      assert state(view).picked == []
    end

    test "the search box posts nothing into the host form", %{conn: conn} do
      view = host(conn, PlaceTree.places("standard"))
      search_box = view |> element("#pp-search") |> render()

      # No name: the form's data never carries it; the hook stops its events
      # and Enter from reaching the form (browser side, pinned in Chrome).
      refute search_box =~ ~s( name=)
      assert search_box =~ ~s(phx-hook=)

      # Every button in the picker is type="button", so none submits the form.
      html = view |> element("#pp") |> render()
      buttons = Regex.scan(~r/<button\b[^>]*>/, html) |> List.flatten()
      assert buttons != []
      assert Enum.all?(buttons, &(&1 =~ ~s(type="button")))

      view |> form("#host-form") |> render_submit()
      assert Map.keys(state(view).submitted) |> Enum.sort() == ["place", "title"]
    end

    test "as a field it shows the path and opens the tree on Change", %{conn: conn} = ctx do
      oak = "category:" <> ctx.oak.uuid
      view = host(conn, PlaceTree.places("standard"), oak, %{field: true})

      assert view |> element("#pp-path") |> render() =~ "Kitchen"
      refute has_element?(view, "#pp-tree")

      view |> element("#pp-change") |> render_click()
      assert has_element?(view, "#pp-tree")

      view |> row("catalogue:" <> ctx.kitchen.uuid) |> render_click()
      refute has_element?(view, "#pp-tree")
      assert view |> element("#pp-path") |> render() =~ "Kitchen"
      refute view |> element("#pp-path") |> render() =~ "Oak"
    end

    test "multiple: rows toggle, and a folder's box takes every catalogue under it",
         %{conn: conn} = ctx do
      {:ok, other} = Catalogue.create_catalogue(%{name: "Bath"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(other, ctx.rooms.uuid)
      tree = PlaceTree.places(nil, categories: false)
      kitchen = "catalogue:" <> ctx.kitchen.uuid
      bath = "catalogue:" <> other.uuid
      folder = "folder:" <> ctx.rooms.uuid

      view = host(conn, tree, [], %{multiple: true, pickable: [:catalogue]})
      assert has_element?(view, ~s(#pp [data-pick-all="#{folder}"] [data-check="none"]))

      view |> element(~s(#pp [data-pick-all="#{folder}"])) |> render_click()
      assert Enum.sort(state(view).value) == Enum.sort([kitchen, bath])
      assert has_element?(view, ~s(#pp [data-pick-all="#{folder}"] [data-check="all"]))

      # A search hiding one of them still leaves the folder's box on the whole branch.
      view |> row(folder) |> render_click()
      view |> row(kitchen) |> render_click()
      assert state(view).value == [bath]
      assert has_element?(view, ~s(#pp [data-pick-all="#{folder}"] [data-check="some"]))

      search(view, "bath")
      view |> element(~s(#pp [data-pick-all="#{folder}"])) |> render_click()
      assert Enum.sort(state(view).value) == Enum.sort([bath, kitchen])

      view |> form("#host-form") |> render_submit()
      # One hidden input per catalogue: the host names it "place" here.
      assert state(view).submitted["place"] in [ctx.kitchen.uuid, other.uuid]
    end
  end
end
