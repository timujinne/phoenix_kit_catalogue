defmodule PhoenixKitCatalogue.Web.ComponentsBranchesTest do
  @moduledoc """
  Render-level branch coverage for the smart-rule helpers + various
  status-rendering paths exposed indirectly through ItemFormLive when
  it mounts on a smart-catalogue item.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    {:ok, smart} = Catalogue.create_catalogue(%{name: "SmartHost", kind: "smart"})
    {:ok, item} = Catalogue.create_item(%{name: "SmartItem", catalogue_uuid: smart.uuid})
    %{smart: smart, item: item}
  end

  # Each rule is one row of the item form's rules picker, found by the
  # catalogue it points at: a checkbox, the value field and the unit select.
  defp rule_checkbox(ref), do: ~s(input[type="checkbox"][phx-value-uuid="#{ref.uuid}"])
  defp rule_value(ref), do: ~s(input[name="value"][phx-value-uuid="#{ref.uuid}"])
  defp rule_unit(ref, unit), do: ~s(#rule-unit-#{ref.uuid} option[value="#{unit}"][selected])

  describe "smart-catalogue ItemFormLive — rules render branches" do
    test "with no standard catalogue to point at, the picker says so", %{conn: conn, item: item} do
      {:ok, view, html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      assert html =~ "No other catalogues available to reference yet."
      refute has_element?(view, ~s(input[name="value"][phx-blur="set_catalogue_rule_value"]))
    end

    test "a rule's stored value shows without its trailing zeros, beside its unit",
         %{conn: conn, item: item} do
      # Create a referenced standard catalogue first, then attach a
      # rule pointing at it.
      {:ok, ref} = Catalogue.create_catalogue(%{name: "RefCat", kind: "standard"})

      {:ok, _rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: ref.uuid,
          value: Decimal.new("15.0000"),
          unit: "percent"
        })

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      assert has_element?(view, rule_checkbox(ref) <> "[checked]")
      assert has_element?(view, rule_value(ref) <> ~s([value="15"]))
      assert has_element?(view, rule_unit(ref, "percent"))
    end

    test "rule with unit: flat renders the gettext label",
         %{conn: conn, item: item} do
      {:ok, ref} = Catalogue.create_catalogue(%{name: "FlatRefCat", kind: "standard"})

      {:ok, _rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: ref.uuid,
          value: Decimal.new("5"),
          unit: "flat"
        })

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      assert has_element?(view, rule_unit(ref, "flat"))
      assert view |> element(rule_unit(ref, "flat")) |> render() =~ "Flat"
    end

    test "a rule with no value is ticked with an empty value field",
         %{conn: conn, item: item} do
      {:ok, ref} = Catalogue.create_catalogue(%{name: "NoValRef", kind: "standard"})

      {:ok, _rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: ref.uuid,
          unit: "percent"
        })

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      assert has_element?(view, rule_checkbox(ref) <> "[checked]")
      assert has_element?(view, rule_value(ref))
      refute has_element?(view, rule_value(ref) <> ~S|[value]:not([value=""])|)
      refute has_element?(view, rule_value(ref) <> "[disabled]")
    end

    test "a catalogue with no rule is unticked and its fields are off",
         %{conn: conn, item: item} do
      {:ok, ref} = Catalogue.create_catalogue(%{name: "UntickedRef", kind: "standard"})

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      refute has_element?(view, rule_checkbox(ref) <> "[checked]")
      assert has_element?(view, rule_value(ref) <> "[disabled]")
    end
  end

  describe "ItemFormLive — set_catalogue_rule_value + set_catalogue_rule_unit" do
    test "ticking a catalogue and leaving its value field stores and shows the value",
         %{conn: conn, item: item} do
      {:ok, ref} = Catalogue.create_catalogue(%{name: "SetValRef", kind: "standard"})

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      view |> element(rule_checkbox(ref)) |> render_click()
      view |> element(rule_value(ref)) |> render_blur(%{"value" => "12.50"})

      rules = :sys.get_state(view.pid).socket.assigns.working_rules
      assert Decimal.equal?(rules[ref.uuid].value, Decimal.new("12.5"))
      assert has_element?(view, rule_value(ref) <> ~s([value="12.5"]))

      # A value that is not a number clears it rather than keeping the old one.
      view |> element(rule_value(ref)) |> render_blur(%{"value" => "abc"})
      assert :sys.get_state(view.pid).socket.assigns.working_rules[ref.uuid].value == nil
    end

    test "set_catalogue_rule_unit with empty string clears the unit",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")
      uuid = Ecto.UUID.generate()

      # Toggle on first, then set unit to empty string.
      render_click(view, "toggle_catalogue_rule", %{"uuid" => uuid})
      render_change(view, "set_catalogue_rule_unit", %{"uuid" => uuid, "unit" => ""})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert get_in(assigns.working_rules, [uuid, :unit]) == nil
    end

    test "set_catalogue_rule_unit ignores unknown rule uuid",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      # Without first toggling, the rule isn't in working_rules. The
      # event should be a no-op.
      before = :sys.get_state(view.pid).socket.assigns.working_rules

      render_change(view, "set_catalogue_rule_unit", %{
        "uuid" => Ecto.UUID.generate(),
        "unit" => "percent"
      })

      assert :sys.get_state(view.pid).socket.assigns.working_rules == before
    end

    test "set_catalogue_rule_value ignores unknown rule uuid",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")

      before = :sys.get_state(view.pid).socket.assigns.working_rules

      render_change(view, "set_catalogue_rule_value", %{
        "uuid" => Ecto.UUID.generate(),
        "value" => "10"
      })

      assert :sys.get_state(view.pid).socket.assigns.working_rules == before
    end

    test "set_catalogue_rule_value with non-decimal raw stores nil",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/items/#{item.uuid}/edit")
      uuid = Ecto.UUID.generate()

      render_click(view, "toggle_catalogue_rule", %{"uuid" => uuid})

      render_change(view, "set_catalogue_rule_value", %{
        "uuid" => uuid,
        "value" => "not a number"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert get_in(assigns.working_rules, [uuid, :value]) == nil
    end
  end
end
