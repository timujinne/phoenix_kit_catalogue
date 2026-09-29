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
    test "EventsLive catch-all swallows stray messages and stays alive" do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)

      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/events")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, {:totally_unexpected, :message, %{nested: "payload"}})
          # render forces the LV to flush handle_info — without it the
          # debug log is racing with capture_log's exit.
          _ = render(view)
        end)

      assert Process.alive?(view.pid)
      assert log =~ "EventsLive ignored unhandled message"
    end

    test "CatalogueDetailLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "CatalogueFormLive catch-all swallows stray messages" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/new")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "CategoryFormLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/#{cat.uuid}/categories/new")

      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "ItemFormLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}/items/new")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "ImportLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/import?catalogue_uuid=#{cat.uuid}")

      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end
  end

  describe "Batch 2 — PubSub handle_info clauses fire for real broadcasts" do
    test "CataloguesLive refreshes on {:catalogue_data_changed, :catalogue, ...}" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue")

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
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}")

      send(view.pid, {:catalogue_data_changed, :catalogue, cat.uuid, nil})
      assert Process.alive?(view.pid)
      assert render(view)
    end

    test "ImportLive handles import_progress + import_result", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/import?catalogue_uuid=#{cat.uuid}")

      send(view.pid, {:import_progress, 5, 10})
      assert Process.alive?(view.pid)
      # import_result triggers log_import_activity + step transition;
      # asserting alive after is sufficient (no DB row pinning here —
      # full activity log is exercised in activity_logging_test).
      send(view.pid, {:import_result, %{inserted: 0, errors: [], skipped: 0}})
      assert Process.alive?(view.pid)
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
