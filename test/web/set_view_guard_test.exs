defmodule PhoenixKitCatalogue.Web.SetViewGuardTest do
  @moduledoc """
  Direct, no-LiveCase/no-Postgres assertions on the `"set_view"` guard —
  duplicated in two places, `ItemSelectorModal.handle_event/3` and
  `CataloguesLive.handle_event/3`, both `when v in [...]`/`in ["table",
  "card", "comfy"]`, each followed by its own catch-all clause. Round-3
  FIX finding I132/F1 (M2): neither guard had a test that pinned "comfy"
  as accepted or an illegal mode as rejected — a typo'd or narrowed guard
  list would have shipped silently.

  Both handlers are called directly against a hand-built socket/assigns —
  no `mount/3`, no Repo. `CataloguesLive`'s guard body persists through
  `ViewConfig.save_view_on/2`, which short-circuits to `{:error, :no_user}`
  for anything but a real `%Auth.User{}` (`save_view/2`),
  so a `nil` `phoenix_kit_current_user` never touches the database.
  `ItemSelectorModal`'s own handler persists through `persist_selector/2`
  -> `ViewConfig.save_selector/2`, which has the matching short-circuit.

  Both modules now reject an illegal mode the same way — a same-day
  catch-all added independently to each (main evolved past what I132/F1
  originally described here): `ItemSelectorModal.handle_event(_event,
  _params, socket), do: {:noreply, socket}` and
  `CataloguesLive.handle_event("set_view", _params, socket), do:
  {:noreply, socket}`. An illegal mode is a
  silent no-op in both: the relevant `view` assign stays whatever it
  already was — verified directly, not assumed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Web.CataloguesLive
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal
  alias PhoenixKitCatalogue.Web.TableConfig

  describe "ItemSelectorModal.handle_event(\"set_view\", ...) guard" do
    # current_user: nil is load-bearing — the handler now also persists
    # the choice (persist_selector/2 -> ViewConfig.save_selector/2), which
    # reads socket.assigns.current_user unconditionally before short-
    # circuiting to {:error, :no_user} for anything but a real
    # %Auth.User{}. Omitting the key here would
    # crash on a plain KeyError instead of exercising that short-circuit.
    defp component_socket(view),
      do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, view: view, current_user: nil}}

    test "each of the three legal modes is accepted and lands in assigns" do
      for mode <- ["table", "comfy", "card"] do
        assert {:noreply, %{assigns: %{view: got}}} =
                 ItemSelectorModal.handle_event(
                   "set_view",
                   %{"mode" => mode},
                   component_socket("unset")
                 )

        assert got == mode
      end
    end

    test "an illegal mode falls through to the catch-all clause: view is left unchanged, not coerced" do
      assert {:noreply, %{assigns: %{view: "table"}}} =
               ItemSelectorModal.handle_event(
                 "set_view",
                 %{"mode" => "grid"},
                 component_socket("table")
               )
    end
  end

  describe "CataloguesLive.handle_event(\"set_view\", ...) guard" do
    # "set_view" persists through ViewConfig.save_view_on/2 directly, not
    # through put_cfg/3 (that path is sort/filter only) — no
    # global_sort?/Settings/PubSub branch is reachable here regardless of
    # scope, so a plain hand-built socket is enough.
    defp live_socket(view) do
      scope = :attribute_groups

      cfg = %{
        columns: TableConfig.default_columns(scope),
        sort_by: elem(TableConfig.default_sort(scope), 0),
        sort_dir: elem(TableConfig.default_sort(scope), 1),
        filters: %{},
        view: view
      }

      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          active_tab: :attribute_groups,
          view_configs: %{attribute_groups: cfg},
          phoenix_kit_current_user: nil
        }
      }
    end

    test "each of the three legal modes is accepted and lands in the scope's cfg" do
      for mode <- ["table", "comfy", "card"] do
        assert {:noreply, socket} =
                 CataloguesLive.handle_event("set_view", %{"mode" => mode}, live_socket("unset"))

        assert socket.assigns.view_configs.attribute_groups.view == mode
      end
    end

    test "an illegal mode falls through to the catch-all clause: cfg is left unchanged" do
      assert {:noreply, socket} =
               CataloguesLive.handle_event("set_view", %{"mode" => "grid"}, live_socket("table"))

      assert socket.assigns.view_configs.attribute_groups.view == "table"
    end
  end
end
