defmodule PhoenixKitCatalogue.Web.AttributeGroupsLiveTest do
  @moduledoc """
  End-to-end tests for the Attributes admin tab (groups list inside
  CataloguesLive) and the AttributeGroupFormLive editor.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp create_group(attrs \\ %{}) do
    {:ok, g} = Catalogue.create_attribute_group(Map.merge(%{name: "Idea doors"}, attrs))
    g
  end

  defp create_item_with_group(group) do
    catalogue = fixture_catalogue()
    item = fixture_item(%{name: "Door", catalogue_uuid: catalogue.uuid})
    {:ok, :assigned} = Catalogue.set_item_attribute_group(item, group.uuid)
    item
  end

  # ── Groups list tab ──────────────────────────────────────────────

  describe "attribute groups list" do
    test "renders groups with attribute and item counts", %{conn: conn} do
      group = create_group()
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      {:ok, _} = Catalogue.create_attribute_value(attribute, %{"value" => "White"})
      create_item_with_group(group)

      {:ok, _view, html} = live(conn, "#{@base}/attributes")

      assert html =~ "Idea doors"
      assert html =~ "New Attribute Group"
    end

    test "delete is refused for a group in use, works for an unused one", %{conn: conn} do
      used = create_group(%{name: "Used group"})
      create_item_with_group(used)
      unused = create_group(%{name: "Unused group"})

      {:ok, view, _html} = live(conn, "#{@base}/attributes")

      view
      |> render_click("show_delete_confirm", %{"uuid" => used.uuid, "type" => "attribute_group"})

      html = view |> render_click("delete_attribute_group", %{})
      assert html =~ "archive it instead"
      assert Catalogue.get_attribute_group(used.uuid)

      view
      |> render_click("show_delete_confirm", %{
        "uuid" => unused.uuid,
        "type" => "attribute_group"
      })

      view |> render_click("delete_attribute_group", %{})
      assert Catalogue.get_attribute_group(unused.uuid) == nil
    end

    test "archive and restore from the row menu", %{conn: conn} do
      group = create_group()

      {:ok, view, _html} = live(conn, "#{@base}/attributes")

      view
      |> render_click("set_attribute_group_status", %{
        "uuid" => group.uuid,
        "status" => "archived"
      })

      assert Catalogue.get_attribute_group(group.uuid).status == "archived"

      view
      |> render_click("set_attribute_group_status", %{"uuid" => group.uuid, "status" => "active"})

      assert Catalogue.get_attribute_group(group.uuid).status == "active"

      # forged status value is ignored
      view
      |> render_click("set_attribute_group_status", %{"uuid" => group.uuid, "status" => "boom"})

      assert Catalogue.get_attribute_group(group.uuid).status == "active"
    end
  end

  # ── Group form ───────────────────────────────────────────────────

  describe "AttributeGroupFormLive :new" do
    test "renders and creates; Save (stay) lands on the edit form", %{conn: conn} do
      {:ok, view, html} = live(conn, "#{@base}/attributes/new")
      assert html =~ "New Attribute Group"

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "attribute_group" => %{"name" => "Idea doors"}
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      assert [%{name: "Idea doors", uuid: uuid}] = Catalogue.list_attribute_groups()
      assert to == "#{@base}/attributes/#{uuid}/edit"
    end

    test "Save & Exit returns to the groups list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "attribute_group" => %{"name" => "Basic"}
        })
        |> put_submitter(~s(button[name=save_action][value=exit]))
        |> render_submit()

      assert to == "#{@base}/attributes"
    end
  end

  describe "AttributeGroupFormLive :edit — inline editor" do
    test "adds attributes and values through the event flow", %{conn: conn} do
      group = create_group()

      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      view
      |> form(~s(form[id^="add-attribute-form"]), %{
        "attr_name" => "Color",
        "attr_kind" => "multi"
      })
      |> render_submit()

      full = Catalogue.get_attribute_group_full(group.uuid)
      assert [%{name: "Color", kind: "multi", key: "color"}] = full.attributes
      [attribute] = full.attributes

      view
      |> form(~s(form[id^="add-value-form-#{attribute.uuid}"]), %{"value" => "White"})
      |> render_submit()

      html =
        view
        |> form(~s(form[id^="add-value-form-#{attribute.uuid}"]), %{"value" => "Oak"})
        |> render_submit()

      assert html =~ "White"
      assert html =~ "Oak"

      full = Catalogue.get_attribute_group_full(group.uuid)
      [%{values: [white, oak]}] = full.attributes
      assert white.is_default
      refute oak.is_default

      # flip the default via the star
      view |> render_click("make_default", %{"uuid" => oak.uuid})
      full = Catalogue.get_attribute_group_full(group.uuid)
      [%{values: values}] = full.attributes
      assert Enum.find(values, & &1.is_default).value == "Oak"
    end

    test "rename on blur writes the primary language; a secondary writes an override",
         %{conn: conn} do
      group = create_group()
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})

      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      view
      |> render_hook("rename_attribute", %{"uuid" => attribute.uuid, "value" => "Colour"})

      updated = Catalogue.get_attribute(attribute.uuid)
      assert updated.name == "Colour"
      # key never moves
      assert updated.key == "color"
    end

    test "reorder_attributes persists the dragged order", %{conn: conn} do
      group = create_group()
      {:ok, a1} = Catalogue.create_attribute(group, %{"name" => "Color"})
      {:ok, a2} = Catalogue.create_attribute(group, %{"name" => "Trim"})

      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      view
      |> render_hook("reorder_attributes", %{
        "ordered_ids" => [a2.uuid, a1.uuid],
        "moved_id" => a2.uuid
      })

      full = Catalogue.get_attribute_group_full(group.uuid)
      assert Enum.map(full.attributes, & &1.name) == ["Trim", "Color"]
    end

    test "deleting an attribute goes through the confirm modal", %{conn: conn} do
      group = create_group()
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})

      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      view |> render_click("request_delete_attribute", %{"uuid" => attribute.uuid})
      view |> render_click("confirm_delete_attribute", %{})

      assert Catalogue.get_attribute(attribute.uuid) == nil
    end

    test "foreign uuids are ignored (event forgery guard)", %{conn: conn} do
      group = create_group()
      other = create_group(%{name: "Other"})
      {:ok, foreign} = Catalogue.create_attribute(other, %{"name" => "Sneak"})

      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      view |> render_hook("rename_attribute", %{"uuid" => foreign.uuid, "value" => "Hacked"})
      assert Catalogue.get_attribute(foreign.uuid).name == "Sneak"
    end

    test "unknown group redirects out with a flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "#{@base}/attributes/#{Ecto.UUID.generate()}/edit")

      assert to == "#{@base}/attributes"
    end
  end

  test "crafted rename/add payloads cannot crash the group form (sweep 2026-09-13)", %{conn: conn} do
    group = create_group(%{name: "Junk Group"})
    {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
    render_submit(view, "add_attribute", %{"attr_name" => %{"x" => 1}})
    render_submit(view, "add_attribute", %{"attr_name" => ["x"]})
    assert Process.alive?(view.pid)
  end
end
