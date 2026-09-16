defmodule PhoenixKitCatalogue.Web.AttributeSetItemsModalTest do
  @moduledoc """
  The set-items popup (2026-08-28: the Items COUNT is the button; the
  preview is a popup, not a page): opening from the listing, the row
  contents (name link, per-item SELECTED values), server-side trimmed
  search, 25/page, deleted-item exclusion, and closing.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Test.Repo

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      %{conn: with_scope(conn, scope)}
    end

    defp modal_id(set), do: "attr-set-items-modal-#{set.uuid}"

    test "count opens the popup: rows with SELECTED labels, item links", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, _blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

      item = fixture_item(%{name: "Popup door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

      # The listing shows the COUNT, not item names.
      refute html =~ "Popup door"
      refute has_element?(view, modal_id(set) |> then(&"##{&1}"))

      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Popup door"
      # The row shows the item's OWN selection of this set…
      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Red")
      refute has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Blue")
      # …and links to the item editor.
      assert has_element?(
               view,
               ~s|##{modal_id(set)} a[href$="/items/#{item.uuid}/edit"]|,
               "Popup door"
             )
    end

    test "popup search is server-side and trailing-space tolerant", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup search"})
      hit = fixture_item(%{name: "Walnut door"})
      miss = fixture_item(%{name: "Steel frame"})
      {:ok, _} = Catalogue.attach_attribute_set(hit.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(miss.uuid, set.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      html =
        view
        |> element("##{modal_id(set)} form")
        |> render_change(%{"q" => "Walnut "})

      assert html =~ "Walnut door"
      refute html =~ "Steel frame"

      html =
        view
        |> element("##{modal_id(set)} form")
        |> render_change(%{"q" => "zzz-nothing"})

      assert html =~ "No items match your search."
      refute html =~ "No items attached."
    end

    test "popup items paginate at 25", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup paged"})

      for n <- 1..26 do
        item = fixture_item(%{name: "Paged item #{String.pad_leading("#{n}", 2, "0")}"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      end

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      assert html =~ "Paged item 01"
      refute html =~ "Paged item 26"
      assert html =~ "1 / 2"

      html =
        view
        |> element(~s|##{modal_id(set)} button[phx-value-dir="next"]|)
        |> render_click()

      assert html =~ "Paged item 26"
      refute html =~ "Paged item 01"
    end

    test "deleted items stay out; zero items means no button", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup trash"})
      kept = fixture_item(%{name: "Kept item"})
      gone = fixture_item(%{name: "Trashed item"})
      {:ok, _} = Catalogue.attach_attribute_set(kept.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(gone.uuid, set.uuid)
      {:ok, _} = Catalogue.trash_item(gone)

      {:ok, empty} = Catalogue.create_attribute_set(%{name: "Popup empty"})

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

      # An unattached set renders a bare muted 0, not a dead button
      # (Max, 2026-08-28).
      refute html =~ "No items attached."

      refute has_element?(
               view,
               ~s|button[phx-click="open_set_items_modal"][phx-value-uuid="#{empty.uuid}"]|
             )

      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Kept item"
      refute html =~ "Trashed item"
    end

    test "a selection archived after being picked still renders, badged (3c)", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup archived selection"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Retired Red"})

      item = fixture_item(%{name: "Archived-select door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(red, %{status: "archived"}, activity_log: false)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      # The bug this replaces: an archived value's label used to vanish
      # from the popup entirely because the label map only looked at
      # active values. It renders, and specifically as the archived
      # (ghost) badge variant, not the normal outline chip.
      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Retired Red")

      assert has_element?(
               view,
               "##{modal_id(set)}-item-#{item.uuid} .badge-ghost",
               "Retired Red"
             )

      refute has_element?(
               view,
               "##{modal_id(set)}-item-#{item.uuid} .badge-outline",
               "Retired Red"
             )

      # And it says so in words, not only by the badge's style.
      assert has_element?(
               view,
               "##{modal_id(set)}-item-#{item.uuid} .badge-ghost",
               "Retired Red (archived)"
             )
    end

    test "a broken set contract degrades labels instead of blanking every chip", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup broken contract"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Broken Red"})

      item = fixture_item(%{name: "Broken-contract door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      # Tamper the contract via the owner bypass — `resolve_set/2` now
      # returns nil for this set (contract_broken), same as a corrupted
      # blueprint in the wild.
      set = AttributeSets.get_set(set.uuid)

      {:ok, _} =
        PhoenixKitEntities.update_entity(
          set,
          %{settings: put_in(set.settings, ["catalogue", "kind"], "not_a_real_kind")},
          on_behalf_of: "catalogue"
        )

      assert AttributeSets.resolve_set(set.uuid) == nil

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

      # The bug this replaces: a broken contract made `resolve_set/2`
      # return nil, which degraded the WHOLE label map to `%{}` — every
      # item's chips for this set vanished, not just the unresolvable
      # one. Degrading to the plain (active-only) value listing keeps
      # the label showing.
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Broken-contract door"
      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Broken Red")
    end

    test "a broken contract's fallback still shows an archived selection's chip", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup broken+hidden"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Ghosted Red"})

      item = fixture_item(%{name: "Broken-hidden door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(red, %{status: "archived"}, activity_log: false)

      # Same contract tamper as the test above, but this time the
      # item's selected value is ALSO archived. `list_attribute_set_values/2`
      # (the fallback's active-only half) excludes it, so the fallback
      # must reach for the hidden half too or this chip blanks —
      # exactly the §3c bug the happy path already fixed, just hit via
      # the broken-contract fallback this time.
      set = AttributeSets.get_set(set.uuid)

      {:ok, _} =
        PhoenixKitEntities.update_entity(
          set,
          %{settings: put_in(set.settings, ["catalogue", "kind"], "not_a_real_kind")},
          on_behalf_of: "catalogue"
        )

      assert AttributeSets.resolve_set(set.uuid) == nil

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Ghosted Red")
    end

    test "a broken contract's fallback dedupes a trashed duplicate's slug too", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup broken+collision"})

      {:ok, old} =
        Catalogue.create_attribute_set_value(set, %{label: "Old Red", slug: "punane"})

      {:ok, _} = PhoenixKitEntities.EntityData.trash(old)

      {:ok, live_value} = Catalogue.create_attribute_set_value(set, %{label: "New Red"})

      # New values no longer reuse a hidden value's slug; legacy rows and
      # writes that bypass this module still can, so force the collision.
      Repo.query!(
        "UPDATE phoenix_kit_entity_data SET slug = $1 WHERE uuid = $2::text::uuid",
        ["punane", live_value.uuid]
      )

      live_value = %{live_value | slug: "punane"}

      assert old.slug == live_value.slug

      item = fixture_item(%{name: "Collision door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [live_value.slug])

      # Same contract tamper as the tests above — this exercises the
      # broken-contract fallback (`fallback_values/2` +
      # `fallback_hidden_values/2`), which builds its label map from
      # two independent listings. Without the shared dedup rule, the
      # trashed row (fetched second, into `hidden_values`) would
      # overwrite the live row's label in `Map.new(values ++
      # hidden_values, ...)` — "last wins" — even though the live value
      # is the one actually selected.
      set = AttributeSets.get_set(set.uuid)

      {:ok, _} =
        PhoenixKitEntities.update_entity(
          set,
          %{settings: put_in(set.settings, ["catalogue", "kind"], "not_a_real_kind")},
          on_behalf_of: "catalogue"
        )

      assert AttributeSets.resolve_set(set.uuid) == nil

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      assert html =~ "Collision door"
      # The live label shows, once — not shadowed by the stale trashed
      # copy sharing its slug.
      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "New Red")
      refute has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Old Red")

      row_html =
        view
        |> element("##{modal_id(set)}-item-#{item.uuid}")
        |> render()

      assert row_html |> String.split("New Red") |> length() == 2
    end

    test "closing unmounts the popup; reopening starts fresh", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup close"})
      item = fixture_item(%{name: "Close item"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      view
      |> element("##{modal_id(set)} form")
      |> render_change(%{"q" => "zzz-nothing"})

      view
      |> element(~s|##{modal_id(set)} button.btn-circle[phx-click="close"]|)
      |> render_click()

      refute has_element?(view, "##{modal_id(set)}")

      # Fresh mount on reopen: the stale search is gone (the
      # media-selector trap).
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Close item"
    end
  end
end
