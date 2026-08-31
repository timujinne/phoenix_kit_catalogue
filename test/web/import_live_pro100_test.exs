defmodule PhoenixKitCatalogue.Web.ImportLivePro100Test do
  @moduledoc """
  Integration tests for the PRO100 sync flow wired into ImportLive.
  Covers source/format selects, the :preview step, apply_pro100 handler,
  and the :report step.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @import_url "/en/admin/catalogue/import"

  # Minimal valid PRO100 furniture file with one data row.
  # Header: "# Parts\t<col_names>"
  # Data: "\t\tname\tid\tc3\tprice\tc5\tc6\tc7"
  defp furniture_file(rows) do
    header = "# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7"
    data = Enum.map(rows, fn {name, id, price} -> "\t\t#{name}\t#{id}\t\t#{price}\t\t\t" end)
    Enum.join([header | data], "\n")
  end

  defp build_file_input(view, filename, content_type, contents) do
    Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
      %{
        last_modified: 1_700_000_000_000,
        name: filename,
        content: contents,
        type: content_type
      }
    ])
  end

  setup do
    cat = fixture_catalogue(%{name: "PRO100 Test Cat"})

    item =
      fixture_item(%{
        name: "Chair Alpha",
        sku: "W-9",
        base_price: "99.00",
        catalogue_uuid: cat.uuid
      })

    %{catalogue: cat, item: item}
  end

  describe "upload_step renders source/format selects" do
    test "upload page shows source select", %{conn: conn} do
      {:ok, _view, html} = live(conn, @import_url)
      assert html =~ "Source"
      assert html =~ "upload-source"
    end
  end

  describe "validate_upload sets selected_source and selected_format" do
    test "selecting pro100 source updates assigns", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid, "source" => "pro100"})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "pro100"
      assert assigns.selected_format == nil
    end

    test "selecting source + format updates both assigns", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      # Changing the source deliberately resets the format (see
      # resolve_selected_format/4), so a single event carrying both a NEW
      # source and a format discards the format. Real usage is two steps:
      # pick the source, then pick the format.
      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100"
      })

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "pro100"
      assert assigns.selected_format == "furniture"
    end

    test "changing source resets format", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      # First pick pro100 + furniture
      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # Then switch to universal — format must reset
      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "universal"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "universal"
      assert assigns.selected_format == nil
    end
  end

  describe "PRO100 sync flow — happy path" do
    test "uploads furniture file and transitions to :preview step",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # The item SKU is "W-9" → digits_id "9". Use "9" as the id in the file.
      txt = furniture_file([{item.name, "9", "150.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :preview
      assert assigns.import_plan != nil
      assert assigns.import_plan.updates != []
    end

    test "apply_pro100 persists price update and transitions to :report",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{item.name, "9", "250.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      render_click(view, "apply_pro100", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :report
      assert assigns.report != nil
      assert assigns.report.updated >= 1

      # Verify the DB item was actually updated
      updated_item = Catalogue.get_item!(item.uuid)
      assert Decimal.equal?(updated_item.base_price, Decimal.new("250.00"))
    end

    test "a second Apply does not re-run the plan", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # An unmatched row, so applying CREATES — the duplication a double
      # Apply produces is visible as a second row rather than an idempotent
      # re-write.
      txt = furniture_file([{"Brand New Chair", "4242", "99.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      before = length(Catalogue.list_items_for_catalogue(cat.uuid))

      render_click(view, "apply_pro100", %{})
      created = length(Catalogue.list_items_for_catalogue(cat.uuid)) - before

      # The second click. LiveView runs events one at a time and this handler
      # is synchronous start to finish, so an "am I running?" flag is always
      # false by the time the second event is dispatched — it could never
      # refuse anything. What distinguishes a second Apply is that the plan
      # has been consumed.
      render_click(view, "apply_pro100", %{})

      assert length(Catalogue.list_items_for_catalogue(cat.uuid)) - before == created
    end

    test "apply_pro100 preserves a photo attached between plan build and Apply",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{item.name, "9", "250.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # The plan is now built from the item's snapshot (no photo). Simulate an
      # operator attaching a main image AFTER the preview but BEFORE Apply — the
      # exact race the whole-`data` snapshot write used to lose.
      {:ok, _} =
        Catalogue.update_item(Catalogue.get_item!(item.uuid), %{
          data: %{"featured_image_uuid" => "photo-race-uuid"}
        })

      render_click(view, "apply_pro100", %{})

      updated = Catalogue.get_item!(item.uuid)
      # Price update still applied…
      assert Decimal.equal?(updated.base_price, Decimal.new("250.00"))
      # …the pro100 blob was still written…
      assert updated.data["pro100"]["format"] == "furniture"
      # …and the photo attached mid-flight survived.
      assert updated.data["featured_image_uuid"] == "photo-race-uuid"
    end
  end

  describe "PRO100 sync flow — guard branches" do
    test "parse_file without format selected flashes error",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100"
        # no format
      })

      txt = furniture_file([{item.name, "9", "100.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      html = render_submit(view, "parse_file", %{"catalogue" => cat.uuid, "source" => "pro100"})

      assert html =~ "Please select a format"
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :upload
    end

    test "parse_file with bad PRO100 content flashes error",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      file = build_file_input(view, "bad.txt", "text/plain", "not a pro100 file\n")
      render_upload(file, "bad.txt")

      html =
        render_submit(view, "parse_file", %{
          "catalogue" => cat.uuid,
          "source" => "pro100",
          "format" => "furniture"
        })

      assert html =~ "format"
      assert :sys.get_state(view.pid).socket.assigns.step == :upload
    end
  end

  describe "import_another resets to upload step" do
    test "after :report, import_another resets source/format and returns to :upload",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{item.name, "9", "55.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      render_click(view, "apply_pro100", %{})
      render_click(view, "import_another", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :upload
      assert assigns.selected_source == "universal"
      assert assigns.selected_format == nil
      assert assigns.report == nil
      assert assigns.import_plan == nil
    end
  end

  describe "force-creating unmatched rows" do
    # The group prefix has to be the selected catalogue's own name: any other
    # prefix is refused by the foreign-group guard before the row is ever
    # considered for creation. The fixture catalogue is "PRO100 Test Cat".
    @prefixed_row "PRO100 Test Cat / MP U741 ST9 16mm"

    # Uploads a file whose single row matches nothing in the catalogue and
    # returns the LiveView sitting on the :preview step.
    defp preview_with_unmatched(conn, cat, name \\ @prefixed_row) do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{name, "7374116", "108.88"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      view
    end

    test "unmatched row lands in :creates with the box checked by default",
         %{conn: conn, catalogue: cat} do
      view = preview_with_unmatched(conn, cat)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.step == :preview
      assert assigns.import_plan.updates == []
      assert [create] = assigns.import_plan.creates
      assert create.attrs.name == "MP U741 ST9 16mm"
      # The prefix is stripped from the name but does NOT become a category:
      # it only names the catalogue we are already importing into.
      assert create.category == nil
      # Nothing to update → the checkbox defaults on.
      assert assigns.create_unmatched
    end

    test "applying creates the item and stays on the sync report",
         %{conn: conn, catalogue: cat} do
      view = preview_with_unmatched(conn, cat)
      render_click(view, "apply_pro100", %{})

      assigns = :sys.get_state(view.pid).socket.assigns

      # Regression guard: Executor.execute/4 sends {:import_result, _}, which
      # this LiveView also handles by switching to the universal import's
      # :done screen. Passing nil as notify_pid is what keeps us here.
      assert assigns.step == :report
      assert assigns.report.created == 1
      assert assigns.report.updated == 0

      items = Catalogue.list_items_for_catalogue(cat.uuid)
      created = Enum.find(items, &(&1.sku == "7374116"))

      assert created.name == "MP U741 ST9 16mm"
      assert Decimal.equal?(created.base_price, Decimal.new("108.88"))
      # unit was omitted from attrs, so the schema default applies — NOT NULL.
      assert created.unit == "piece"
      assert created.status == "active"
      assert created.data["pro100"]["format"] == "furniture"
      # Same placement as an unprefixed row: the catalogue root.
      assert is_nil(created.category_uuid)
    end

    test "with the box unchecked nothing is created and the rows are still reported",
         %{conn: conn, catalogue: cat} do
      view = preview_with_unmatched(conn, cat)
      render_click(view, "toggle_create_unmatched", %{})

      refute :sys.get_state(view.pid).socket.assigns.create_unmatched

      render_click(view, "apply_pro100", %{})
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.report.created == 0
      # The row must not vanish from the report just because it was not created.
      assert [%{reason: :not_imported}] = assigns.report.skipped

      items = Catalogue.list_items_for_catalogue(cat.uuid)
      refute Enum.any?(items, &(&1.sku == "7374116"))
    end

    test "a row with no group prefix is created without a category",
         %{conn: conn, catalogue: cat} do
      view = preview_with_unmatched(conn, cat, "MP U767 PM/ST9 18mm")
      render_click(view, "apply_pro100", %{})

      created =
        cat.uuid
        |> Catalogue.list_items_for_catalogue()
        |> Enum.find(&(&1.sku == "7374116"))

      # The bare slash in the article code must not be read as a group split.
      assert created.name == "MP U767 PM/ST9 18mm"
      assert is_nil(created.category_uuid)
    end

    # The two halves of this feature were built on separate branches — creation
    # of unmatched rows, then the foreign-group guard — and the guard runs
    # first. A row prefixed with anything other than the selected catalogue's
    # name never reaches :creates, whatever the checkbox says.
    test "a row from another group is refused, not created",
         %{conn: conn, catalogue: cat} do
      view = preview_with_unmatched(conn, cat, "Andi Karkass / MP U741 ST9 16mm")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.import_plan.creates == []
      assert [%{reason: :foreign_group, group: "Andi Karkass"}] = assigns.import_plan.skipped

      render_click(view, "apply_pro100", %{})

      assert :sys.get_state(view.pid).socket.assigns.report.created == 0

      refute cat.uuid
             |> Catalogue.list_items_for_catalogue()
             |> Enum.any?(&(&1.sku == "7374116"))
    end
  end
end
