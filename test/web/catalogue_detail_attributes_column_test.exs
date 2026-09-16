defmodule PhoenixKitCatalogue.Web.CatalogueDetailAttributesColumnTest do
  @moduledoc """
  The detail page's "Attributes" list column reads `attribute_text`
  (`Components.attribute_cell_text/1` over `attribute_map`), which
  `merge_row_indicators/3` used to fill from the legacy
  `Catalogue.item_attribute_group_map/1` (the `phoenix_kit_cat_
  item_attribute_groups` table). Real attribute bindings live in the
  entities-backed attribute SETS (`phoenix_kit_cat_item_attribute_sets`),
  so an item attaching only a set rendered as "—" everywhere. These
  tests pin the column (table and card view) reading the batched set
  resolve instead, showing the selected values' labels.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  @base "/en/admin/catalogue"

  defp cat_url(cat_uuid, category_uuid), do: "#{@base}/#{cat_uuid}?category=#{category_uuid}"

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    test "the Attributes column shows the selected value's label, not a dash", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes doors"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Door color"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Punane"})

      with_set =
        fixture_item(%{
          name: "With set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      _without_set =
        fixture_item(%{
          name: "Without set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(with_set.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(with_set.uuid, set.uuid, [red.slug])

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      # The attached item's row carries the selected value's label —
      # never just the swatch icon with nothing readable next to it.
      with_set_row = row_segment(html, "With set")
      assert with_set_row =~ "Punane"

      # The unattached item's row carries no attribute label — "—" alone
      # isn't distinctive (other empty cells in the row render it too).
      without_set_row = row_segment(html, "Without set")
      refute without_set_row =~ "Punane"
      refute without_set_row =~ "Door color"

      # The name-adjacent swatch indicator (presence only) is untouched.
      assert has_element?(view, ~s|[title="Has attribute set"]|)
    end

    test "an item with an attached set but no selection shows the set's name", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes trims"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Trim finish"})
      {:ok, _gold} = Catalogue.create_attribute_set_value(set, %{label: "Gold"})

      item =
        fixture_item(%{
          name: "Whole set item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      row = row_segment(html, "Whole set item")
      assert row =~ set.display_name
    end

    test "the card view also shows the selected value's label, not a dash", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes card doors"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Card color"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Punane"})

      with_set =
        fixture_item(%{
          name: "Card with set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      without_set =
        fixture_item(%{
          name: "Card without set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(with_set.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(with_set.uuid, set.uuid, [red.slug])

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      # `<:card_body>` (catalogue_detail_live.ex) is the OTHER surface
      # `attribute_cell_text/1` feeds — the `<tr>`-scoped assertions above
      # never touch it, so this pins it directly via each item's card div.
      assert card_segment(html, with_set.uuid) =~ "Punane"
      refute card_segment(html, without_set.uuid) =~ "Punane"
    end

    test "a selected value trashed or archived afterwards keeps its label (hidden, not a ghost)",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes hidden"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Hidden finish"})
      {:ok, silver} = Catalogue.create_attribute_set_value(set, %{label: "Silver"})
      {:ok, bronze} = Catalogue.create_attribute_set_value(set, %{label: "Bronze"})

      item =
        fixture_item(%{
          name: "Hidden item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      :ok =
        Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [silver.slug, bronze.slug])

      # Both selected values are hidden after the selection was made. The
      # resolve keeps them in `:selected` (§3c), so the column must keep
      # their labels — falling back to the set's name would read as
      # "whole set applies", a mode the item never had.
      {:ok, _} = PhoenixKitEntities.EntityData.trash(silver)

      {:ok, _} =
        PhoenixKitEntities.EntityData.update(bronze, %{status: "archived"}, activity_log: false)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      row = row_segment(html, "Hidden item")
      assert row =~ "Silver"
      assert row =~ "Bronze"
      refute row =~ set.display_name
    end

    test "a selection whose values are all deleted for good shows the set's name (ghost rule)",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes ghosted"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Ghost finish"})
      {:ok, silver} = Catalogue.create_attribute_set_value(set, %{label: "Silver"})

      item =
        fixture_item(%{
          name: "Ghost item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [silver.slug])

      # Hard delete: the slug is gone from every record, so the ghost rule
      # degrades the selection to "whole set applies" rather than
      # vanishing the set or leaving a blank cell.
      {:ok, _} = Catalogue.delete_attribute_set_value(set, silver)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      row = row_segment(html, "Ghost item")
      assert row =~ set.display_name
      refute row =~ "Silver"
    end

    test "resolve only runs when the Attributes column is configured to show", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes gated"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Gate finish"})
      {:ok, gold} = Catalogue.create_attribute_set_value(set, %{label: "Gold"})

      item =
        fixture_item(%{
          name: "Gated item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [gold.slug])

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      # Column not configured: presence only, no label data in the assign.
      assert :sys.get_state(view.pid).socket.assigns.attribute_map[item.uuid] == true

      # Column added: the full resolve replaces the presence marker.
      render_click(view, "add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      assert [%{name: "Gate finish"}] =
               :sys.get_state(view.pid).socket.assigns.attribute_map[item.uuid]

      # Column removed again: back to presence only.
      render_click(view, "remove_column", %{
        "column_id" => "attributes",
        "scope" => "detail_items"
      })

      assert :sys.get_state(view.pid).socket.assigns.attribute_map[item.uuid] == true
    end

    test "a PubSub attribute_set broadcast refreshes the column", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes handles"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Handle finish"})
      {:ok, brass} = Catalogue.create_attribute_set_value(set, %{label: "Brass"})

      item =
        fixture_item(%{
          name: "Handle item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      render_click(view, "add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [brass.slug])

      html = render(view)
      assert row_segment(html, "Handle item") =~ "Brass"
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end

  # Cuts the enclosing `<tr>…</tr>` around one item's name so assertions
  # stay scoped to that table row instead of matching anywhere on the
  # page. This relies on the table being rendered BEFORE the card markup
  # in `table_default`, so the FIRST occurrence of the name is the table
  # cell; if that order ever flips, `last_tag_start/2` falls back to 0
  # and the window stops meaning a row (the test then fails loudly
  # rather than passing by accident).
  defp row_segment(html, needle) do
    case :binary.match(html, needle) do
      {idx, _len} ->
        row_start = last_tag_start(html, idx)
        row_end = row_end(html, idx)
        binary_part(html, row_start, row_end - row_start)

      :nomatch ->
        flunk("expected #{inspect(needle)} in rendered HTML")
    end
  end

  defp last_tag_start(html, idx) do
    case html |> :binary.matches("<tr") |> Enum.filter(fn {s, _} -> s <= idx end) do
      [] -> 0
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp row_end(html, idx) do
    case :binary.match(html, "</tr>", scope: {idx, byte_size(html) - idx}) do
      {end_idx, end_len} -> end_idx + end_len
      :nomatch -> byte_size(html)
    end
  end

  # Cuts the card `<div data-id="…">` for one item. The desktop table
  # markup renders BEFORE the card grid (`data-card-view`) in
  # `table_default`, both carrying the same `data-id`, so this jumps past
  # `data-card-view` first to land on the card's `data-id`, not the
  # table row's. The window ends at the next `data-id="` occurrence
  # (the following card, or nothing) capped at 4000 bytes so a missing
  # boundary can't swallow the rest of the page into a `refute`.
  defp card_segment(html, item_uuid) do
    {card_view_idx, _} = :binary.match(html, "data-card-view")
    scope = {card_view_idx, byte_size(html) - card_view_idx}

    case :binary.match(html, ~s(data-id="#{item_uuid}"), scope: scope) do
      {idx, _len} ->
        window_end = min(idx + 4000, byte_size(html))
        next_scope = {idx + 1, window_end - idx - 1}

        segment_end =
          case :binary.match(html, ~s(data-id="), scope: next_scope) do
            {next_idx, _} -> next_idx
            :nomatch -> window_end
          end

        binary_part(html, idx, segment_end - idx)

      :nomatch ->
        flunk("expected a card for #{inspect(item_uuid)} in rendered HTML")
    end
  end
end
