defmodule PhoenixKitCatalogue.Web.Revalidation20260428Test do
  @moduledoc """
  Pins the deltas introduced during the 2026-04-28 re-validation pass
  (Batch 2 + Batch 3 of PR #14). Each test pairs with a specific
  change; if the change reverts, the corresponding test here fails.

  See `dev_docs/pull_requests/2026/14-quality-sweep/FOLLOW_UP.md`
  Batch 2 / Batch 3 sections for the revert-fail mapping.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Import.Mapper
  alias PhoenixKitCatalogue.Web.Helpers, as: WebHelpers

  import ExUnit.CaptureLog

  setup do
    cat = fixture_catalogue()
    %{catalogue: cat}
  end

  describe "Batch 2 — handle_info catch-all on every admin LV" do
    setup do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
    end

    # The message is sent and the view rendered inside the capture: the
    # render is what makes the view process the message, so the debug line
    # is in the log by the time the capture ends — and a view that crashed
    # on the message fails the render.
    defp assert_stray_message_ignored(view, name) do
      log =
        capture_log([level: :debug], fn ->
          send(view.pid, {:totally_unexpected, :message, %{nested: "payload"}})
          assert is_binary(render(view))
        end)

      assert log =~ "#{name} ignored unhandled message: {:totally_unexpected, :message"
    end

    test "EventsLive" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/events")
      assert_stray_message_ignored(view, "EventsLive")
    end

    test "CatalogueDetailLive", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/#{cat.uuid}")
      assert_stray_message_ignored(view, "CatalogueDetailLive")
    end

    test "CatalogueFormLive" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/new")
      assert_stray_message_ignored(view, "CatalogueFormLive")
    end

    test "CategoryFormLive", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogues/#{cat.uuid}/categories/new")

      assert_stray_message_ignored(view, "CategoryFormLive")
    end

    test "ItemFormLive", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/#{cat.uuid}/items/new")
      assert_stray_message_ignored(view, "ItemFormLive")
    end

    test "ImportLive", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogues/import?catalogue_uuid=#{cat.uuid}")

      assert_stray_message_ignored(view, "ImportLive")
    end

    test "SettingsLive" do
      {:ok, view, _html} = live(conn(), "/en/admin/settings/catalogues")
      assert_stray_message_ignored(view, "SettingsLive")
    end
  end

  # A payload the page never offers — a stale tab, a crafted push — is
  # ignored with a debug line, not a crashed view.
  describe "handle_event catch-all" do
    setup do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
    end

    test "CatalogueDetailLive ignores a column or sort event naming an unknown value",
         %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/#{cat.uuid}")

      log =
        capture_log([level: :debug], fn ->
          for {event, params} <- [
                {"add_column", %{"column_id" => "sku", "section" => "no_such_section"}},
                {"remove_column", %{"column_id" => "sku", "section" => "catalogues"}},
                {"reorder_columns", %{"ordered_ids" => [], "section" => 1}},
                {"no_such_event", %{}}
              ] do
            assert is_binary(render_hook(view, event, params))
          end
        end)

      for event <- ~w(add_column remove_column reorder_columns no_such_event) do
        assert log =~ ~s(CatalogueDetailLive ignored unhandled event: "#{event}")
      end
    end

    test "the item form's PDF search ignores an event it does not know", %{catalogue: cat} do
      item = fixture_item(%{name: "Oak Panel", catalogue_uuid: cat.uuid})
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/items/#{item.uuid}/edit")
      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      log =
        capture_log([level: :debug], fn ->
          html = view |> with_target("#item-pdf-search") |> render_hook("no_such_event", %{})
          assert html =~ "item-pdf-search-query-form"
        end)

      assert log =~ ~s(PdfSearchModal ignored unhandled event: "no_such_event")
    end
  end

  describe "Batch 2 — PubSub handle_info clauses fire for real broadcasts" do
    test "CataloguesLive refreshes on {:catalogue_data_changed, :catalogue, ...}" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues")

      # Real broadcast shape from PubSub.broadcast_data_changed/3
      send(
        view.pid,
        {:catalogue_data_changed, :catalogue, "00000000-0000-0000-0000-000000000000", nil}
      )

      assert Process.alive?(view.pid)
      # Re-render shouldn't crash
      assert render(view)
    end

    test "CatalogueDetailLive refreshes on a :catalogue change for its uuid", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogues/#{cat.uuid}")

      send(view.pid, {:catalogue_data_changed, :catalogue, cat.uuid, nil})
      assert Process.alive?(view.pid)
      assert render(view)
    end

    test "ImportLive takes import_progress, and ignores a result with no import running",
         %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogues/import?catalogue_uuid=#{cat.uuid}")

      send(view.pid, {:import_progress, 5, 10})
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert {assigns.import_progress, assigns.import_total} == {5, 10}

      # A result with no import running is one from a wizard already
      # abandoned: it must not move this one to the done step.
      send(view.pid, {:import_result, %{created: 3, errors: []}})
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :upload
      assert assigns.import_result == nil
    end
  end

  describe "Batch 2 — phx-disable-with on destructive remove/clear buttons" do
    # The remove_file button moved into the shared attachments panel
    # (Components.attachments_files_panel) that all three forms render,
    # so one scan covers catalogue, category, and item alike.
    test "shared attachments panel has phx-disable-with on remove_file button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="remove_file"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a remove_file button in components.ex"
      assert block =~ "phx-disable-with"
    end

    test "components.ex has phx-disable-with on every remove_meta_field button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      blocks =
        Regex.scan(~r/<button[^>]*?phx-click="remove_meta_field"[^>]*?>/s, source)
        |> List.flatten()

      assert length(blocks) >= 2,
             "Expected ≥2 remove_meta_field button declarations (active + legacy)"

      Enum.each(blocks, fn block ->
        assert block =~ "phx-disable-with",
               "Missing phx-disable-with on remove_meta_field button: #{block}"
      end)
    end

    test "components.ex has phx-disable-with on clear_featured_image button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="clear_featured_image"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a clear_featured_image button in components.ex"
      assert block =~ "phx-disable-with"
    end

    test "import_live.ex has phx-disable-with on clear_file button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/import_live.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="clear_file"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a clear_file button in import_live.ex"
      assert block =~ "phx-disable-with"
    end
  end

  describe "Batch 2 — translate_target/1 covers every label from Mapper.available_targets/0" do
    test "every available_target label has a literal-clause translator" do
      # Catches the bug where a new label in Mapper.available_targets/0
      # is not added to import_live.ex's translate_target/1 — which
      # makes the extractor invisible to gettext.extract and leaves the
      # UI label untranslated.
      labels = Enum.map(Mapper.available_targets(), &elem(&1, 1))

      source = File.read!("lib/phoenix_kit_catalogue/web/import_live.ex")

      Enum.each(labels, fn label ->
        # Each label should appear inside a literal `defp translate_target("…"),`
        # clause (the catch-all `defp translate_target(label), do: label` is
        # not enough — the extractor would miss it).
        escaped = Regex.escape(label)
        pattern = ~r/defp\s+translate_target\(\"#{escaped}\"\)/

        assert Regex.match?(pattern, source),
               "Mapper label #{inspect(label)} has no `defp translate_target/1` clause in import_live.ex — extractor invisible."
      end)
    end
  end

  describe "Batch 4 — log_operation_error/3 writes db_pending audit row" do
    test "derive_activity_action/2 maps every LV operation to the canonical atom" do
      # Every LV operation string passed to `log_operation_error/3`
      # must derive to the same action atom the success path uses.
      # If the catalogue context renames an action (or adds a new
      # mutation verb), this table needs to keep up.
      cases = [
        {"trash_item", "item", "item.trashed"},
        {"restore_item", "item", "item.restored"},
        {"permanently_delete_item", "item", "item.permanently_deleted"},
        {"trash_category", "category", "category.trashed"},
        {"restore_category", "category", "category.restored"},
        {"permanently_delete_category", "category", "category.permanently_deleted"},
        {"trash_catalogue", "catalogue", "catalogue.trashed"},
        {"restore_catalogue", "catalogue", "catalogue.restored"},
        {"permanently_delete_catalogue", "catalogue", "catalogue.permanently_deleted"},
        {"delete_manufacturer", "manufacturer", "manufacturer.deleted"},
        {"delete_supplier", "supplier", "supplier.deleted"}
      ]

      Enum.each(cases, fn {operation, entity_type, expected_action} ->
        assert WebHelpers.derive_activity_action(operation, entity_type) == expected_action,
               "Operation #{operation} on #{entity_type} should derive #{expected_action}"
      end)
    end

    test "unknown operation derives nil (no audit row written)" do
      assert WebHelpers.derive_activity_action("frobnicate_widget", "widget") == nil
      assert WebHelpers.derive_activity_action("trash_item", nil) == nil
    end

    test "log_operation_error/3 surfaces error_keys for changeset failures" do
      # Synthetic invocation: build a changeset error reason and check
      # the audit row carries the changeset's error keys (PII-safe —
      # field names only, never user-typed values).
      cat = fixture_catalogue(%{name: "Synthetic Cat"})

      # Build a changeset with a known error key without invoking
      # actual mutation paths.
      cs =
        %PhoenixKitCatalogue.Schemas.Catalogue{}
        |> Ecto.Changeset.cast(%{name: ""}, [:name])
        |> Ecto.Changeset.validate_required([:name])

      socket = %Phoenix.LiveView.Socket{
        view: PhoenixKitCatalogue.Web.CataloguesLive,
        assigns: %{phoenix_kit_current_user: nil}
      }

      capture_log(fn ->
        :ok =
          WebHelpers.log_operation_error(socket, "trash_catalogue", %{
            entity_type: "catalogue",
            entity_uuid: cat.uuid,
            reason: cs
          })
      end)

      row =
        assert_activity_logged("catalogue.trashed",
          resource_uuid: cat.uuid,
          metadata_has: %{"db_pending" => true, "error_kind" => "changeset"}
        )

      assert "name" in (row.metadata["error_keys"] || []),
             "Expected error_keys to include the changeset's error field names; got #{inspect(row.metadata)}"
    end

    test "log_operation_error/3 surfaces atom reasons in metadata" do
      cat = fixture_catalogue(%{name: "Atom Reason Cat"})

      socket = %Phoenix.LiveView.Socket{
        view: PhoenixKitCatalogue.Web.CataloguesLive,
        assigns: %{phoenix_kit_current_user: nil}
      }

      capture_log(fn ->
        :ok =
          WebHelpers.log_operation_error(socket, "trash_catalogue", %{
            entity_type: "catalogue",
            entity_uuid: cat.uuid,
            reason: :would_create_cycle
          })
      end)

      assert_activity_logged("catalogue.trashed",
        resource_uuid: cat.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "reason" => "would_create_cycle"
        }
      )
    end

    test "log_operation_error/3 never logs PII-shaped values in metadata" do
      # Even when the reason is a changeset whose attempted name was
      # PII (an email, for example), the audit row must surface only
      # the field name `name`, never the value.
      cat = fixture_catalogue(%{name: "PII Safety Cat"})

      cs =
        %PhoenixKitCatalogue.Schemas.Catalogue{}
        |> Ecto.Changeset.cast(%{name: "user@private.example"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is reserved")

      socket = %Phoenix.LiveView.Socket{
        view: PhoenixKitCatalogue.Web.CataloguesLive,
        assigns: %{phoenix_kit_current_user: nil}
      }

      capture_log(fn ->
        :ok =
          WebHelpers.log_operation_error(socket, "trash_catalogue", %{
            entity_type: "catalogue",
            entity_uuid: cat.uuid,
            reason: cs
          })
      end)

      row =
        assert_activity_logged("catalogue.trashed",
          resource_uuid: cat.uuid,
          metadata_has: %{"db_pending" => true}
        )

      metadata_str = inspect(row.metadata)

      refute metadata_str =~ "user@private.example",
             "Audit metadata must never contain user-typed values; got #{metadata_str}"
    end
  end

  defp conn, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
end
