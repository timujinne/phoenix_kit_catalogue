defmodule PhoenixKitCatalogue.Web.ItemFormSetsTest do
  @moduledoc """
  The item form's attribute-sets tab (2026-08-18 rework): staging
  attach/detach, the boss's two-modes checkbox selection, and the save
  that applies staged state through the context. Pins the
  browser-verified behaviors the quality sweep found untested (C11,
  2026-08-19).
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Form colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

      cat = fixture_catalogue(%{name: "SetsCat"})
      item = fixture_item(%{name: "SetsItem", catalogue_uuid: cat.uuid})

      %{conn: with_scope(conn, scope), set: set, red: red, blue: blue, item: item}
    end

    defp open(conn, item), do: live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

    defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

    defp save(view) do
      view
      |> form("form[action=\"#\"][phx-submit=save]", %{"item" => %{}})
      |> render_submit()
    end

    test "attach stages the set and save persists the attachment", %{
      conn: conn,
      item: item,
      set: set
    } do
      {:ok, view, html} = open(conn, item)
      assert html =~ "Form colors"
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []

      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == [set.uuid]
      # Staged only — nothing persisted until save.
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []

      save(view)
      assert [%{set_uuid: attached}] = Catalogue.list_attribute_set_attachments(item.uuid)
      assert attached == set.uuid
    end

    test "a forged attach_set for an archived set's uuid is refused", %{
      conn: conn,
      item: item,
      set: set
    } do
      # The picker only offers `available_sets` (`list_attribute_sets/1`,
      # active-only by default), so an archived set never appears as an
      # option — but the event handler itself is the real gate: a
      # forged client payload naming an archived set's uuid directly
      # must not ride the same code path a legit pick would.
      {:ok, _} = Catalogue.archive_attribute_set(set)

      {:ok, view, _html} = open(conn, item)

      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == []

      save(view)
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []
    end

    test "toggle_value_selection stages ticks and save writes them", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      {:ok, view, _html} = open(conn, item)
      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})

      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => blue.slug})
      # Untick red again — several → one.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})

      # Junk pushes are ignored: unknown key, unstaged set.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => "ghost"})

      render_click(view, "toggle_value_selection", %{
        "set" => Ecto.UUID.generate(),
        "key" => red.slug
      })

      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      save(view)

      assert %{sets: [%{selected: selected}]} =
               Catalogue.resolve_attribute_sets_for_item(item.uuid)

      assert selected == [blue.slug]
    end

    test "stored selections hydrate on mount and detach drops them", %{
      conn: conn,
      item: item,
      set: set,
      red: red
    } do
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug, "ghost"])

      {:ok, view, _html} = open(conn, item)

      # Ghosts are intersected away on hydration (single ghost rule).
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([red.slug])

      render_click(view, "detach_set", %{"uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == []
      assert assigns(view).staged_selections[set.uuid] == nil

      save(view)
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []
    end

    test "sets tab replaces the legacy group card when sets are live", %{
      conn: conn,
      item: item
    } do
      {:ok, _view, html} = open(conn, item)
      assert html =~ "Form colors"
      refute html =~ "phx-change=\"select_attribute_group\""
    end

    test "an archived set is not offered for new attachments", %{conn: conn, item: item} do
      {:ok, archived} = Catalogue.create_attribute_set(%{name: "Retired trims"})
      {:ok, _} = Catalogue.archive_attribute_set(archived)

      {:ok, view, html} = open(conn, item)

      refute assigns(view).available_sets |> Enum.any?(&(&1.uuid == archived.uuid))
      refute html =~ "Retired trims"
    end

    test "an already-attached set that gets archived keeps showing (badged) and stays detachable",
         %{conn: conn, item: item, set: set} do
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      {:ok, _} = Catalogue.archive_attribute_set(set)

      {:ok, view, html} = open(conn, item)

      assert html =~ "Form colors"
      assert html =~ "Archived"
      assert assigns(view).staged_set_uuids == [set.uuid]

      render_click(view, "detach_set", %{"uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == []

      save(view)
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []
    end

    test "a selected value archived after being picked stays selected and renders as archived",
         %{conn: conn, item: item, set: set, red: red, blue: blue} do
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug, blue.slug])

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(red, %{status: "archived"}, activity_log: false)

      {:ok, view, html} = open(conn, item)

      # Both slugs survive hydration — archiving Red must not silently
      # drop it from the item's staged selection.
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([red.slug, blue.slug])
      # Rendered read-only and marked archived, not as a live checkbox.
      assert html =~ "Red"
      assert html =~ "Selected, but archived"

      save(view)

      assert %{sets: [%{selected: selected}]} =
               Catalogue.resolve_attribute_sets_for_item(item.uuid)

      assert Enum.sort(selected) == Enum.sort([red.slug, blue.slug])
    end

    test "a forged toggle cannot select an unselected archived value", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [blue.slug])

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(red, %{status: "archived"}, activity_log: false)

      {:ok, view, _html} = open(conn, item)

      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      # `known_value_key?/2` widens the gate to `values ++ hidden_values`
      # so the hidden chip's × button can remove an already-selected
      # archived value. A forged click on an UNselected archived value
      # must not ride that same gate into adding it — invariant 2 says
      # an archived value is never offered for a NEW pick, and the
      # checkboxes already honor that; the write path must too.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      save(view)

      assert %{sets: [%{selected: selected}]} =
               Catalogue.resolve_attribute_sets_for_item(item.uuid)

      assert selected == [blue.slug]
    end

    test "a hidden selected value can be un-selected, and keeps its swatch thumb", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      {:ok, _} = AttributeSets.add_extra_field(set, %{label: "Swatch", type: "image"})
      set = AttributeSets.get_set(set.uuid)
      media_uuid = Ecto.UUID.generate()
      {:ok, _} = AttributeSets.update_value(set, red, %{extras: %{"swatch" => media_uuid}})

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug, blue.slug])

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(red, %{status: "archived"}, activity_log: false)

      {:ok, view, _html} = open(conn, item)

      # The swatch survives archiving too — the same loss family as the
      # label put_thumbs/1 already keeps (put_thumbs used to build the
      # thumb map from `values` alone, so a hidden value's swatch
      # silently disappeared even though its chip still rendered).
      assert assigns(view).set_previews[set.uuid].thumbs[red.slug] == media_uuid

      # The × on the hidden chip un-selects it — detaching the WHOLE
      # set was, until now, the only way to drop a hidden pick.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      save(view)

      assert %{sets: [%{selected: selected}]} =
               Catalogue.resolve_attribute_sets_for_item(item.uuid)

      assert selected == [blue.slug]
    end

    test "a toggle_value_selection payload without a key does not crash the view and leaves staged selections untouched",
         %{conn: conn, item: item, set: set, blue: blue} do
      {:ok, view, _html} = open(conn, item)
      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => blue.slug})
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      # A value row with a NULL slug (seen in live data; the catalogue's
      # own create/update paths never produce one) has no
      # `phx-value-key` on its checkbox, so a click sends just `"set"`
      # and a bare `"value" => "on"` — no `"key"` at all. The lone
      # clause pattern-matches `%{"set" => _, "key" => _}` and used to
      # raise FunctionClauseError, killing the LiveView and rolling
      # back every unsaved tick with it.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "value" => "on"})

      assert Process.alive?(view.pid)
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])
    end

    test "a value with a nil slug renders disabled, without phx-click or phx-value-key", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      # `create_attribute_set_value/2` always generates a slug; force
      # the real-world state (a NULL slug column, seen in live data —
      # entities' changeset accepts one) directly through the repo.
      {1, nil} =
        PhoenixKit.RepoHelper.repo().update_all(
          from(e in PhoenixKitEntities.EntityData, where: e.uuid == ^red.uuid),
          set: [slug: nil]
        )

      {:ok, view, _html} = open(conn, item)
      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      html = render(view)

      assert html =~ "This value has no slug and cannot be selected"
      # Blue (a normal value) still gets a live, clickable checkbox.
      assert html =~ ~s(phx-value-key="#{blue.slug}")

      [red_label] =
        Regex.run(~r/<label[^>]*>(?:(?!<\/?label).)*Red(?:(?!<\/?label).)*<\/label>/s, html)

      assert red_label =~ "disabled"
      refute red_label =~ "phx-click"
      refute red_label =~ "phx-value-key"
    end

    test "two slugless values each keep their own swatch", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      {:ok, _} = AttributeSets.add_extra_field(set, %{label: "Swatch", type: "image"})
      set = AttributeSets.get_set(set.uuid)

      {:ok, _} =
        AttributeSets.update_value(set, red, %{extras: %{"swatch" => Ecto.UUID.generate()}})

      {2, nil} =
        PhoenixKit.RepoHelper.repo().update_all(
          from(e in PhoenixKitEntities.EntityData, where: e.uuid in ^[red.uuid, blue.uuid]),
          set: [slug: nil]
        )

      {:ok, view, _html} = open(conn, item)
      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      html = render(view)

      # Both values carry key nil. A thumbs map keyed on the value key
      # held ONE `nil` entry — Blue's (no swatch, written last) — so
      # Red's chip lost its swatch. Slugless chips compute their own.
      refute Map.has_key?(assigns(view).set_previews[set.uuid].thumbs, nil)

      label_for = fn name ->
        [label] =
          Regex.run(
            ~r/<label[^>]*>(?:(?!<\/?label).)*#{name}(?:(?!<\/?label).)*<\/label>/s,
            html
          )

        label
      end

      assert label_for.("Red") =~ "<img"
      refute label_for.("Blue") =~ "<img"
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
