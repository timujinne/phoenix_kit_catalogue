defmodule PhoenixKitCatalogue.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Errors

  describe "message/1 — atoms" do
    test "would_create_cycle" do
      assert Errors.message(:would_create_cycle) ==
               "Cannot move a category under itself or one of its descendants."
    end

    test "cross_catalogue" do
      assert Errors.message(:cross_catalogue) ==
               "Target belongs to a different catalogue. Move the category to the target catalogue first."
    end

    test "parent_not_found" do
      assert Errors.message(:parent_not_found) == "Parent category not found."
    end

    test "not_siblings" do
      assert Errors.message(:not_siblings) ==
               "Categories must share the same parent to be reordered."
    end

    test "category_not_found" do
      assert Errors.message(:category_not_found) == "Category not found."
    end

    test "catalogue_not_found" do
      assert Errors.message(:catalogue_not_found) == "Catalogue not found."
    end

    test "same_catalogue" do
      assert Errors.message(:same_catalogue) == "Item is already in this catalogue."
    end

    test "no_user" do
      assert Errors.message(:no_user) == "You must be logged in to upload files."
    end

    test "unsupported" do
      assert Errors.message(:unsupported) == "Unsupported file format."
    end

    test "unsupported_file_format" do
      assert Errors.message(:unsupported_file_format) ==
               "Unsupported file format. Please upload .xlsx or .csv."
    end

    test "not_found" do
      assert Errors.message(:not_found) == "Not found."
    end

    test "missing_item_name" do
      assert Errors.message(:missing_item_name) == "Missing item name."
    end

    test "csv_empty" do
      assert Errors.message(:csv_empty) == "CSV file is empty."
    end

    test "parent_catalogue_deleted" do
      assert Errors.message(:parent_catalogue_deleted) ==
               "Cannot restore — the parent catalogue is deleted. Restore the catalogue first."
    end

    # `:pdf_invalid_format` and `:pdf_extraction_failed` removed
    # 2026-05-06 (Phase 2 sweep) — neither had a caller. The PDF
    # library upload pipeline rejects non-PDF MIME at the LV's
    # `accept` attr, and the worker stores extraction errors as
    # raw strings in `error_message` for direct LV display, never
    # routing through `Errors.message/1`.
  end

  describe "message/1 — tagged tuples" do
    test "{:referenced_by_smart_items, count}" do
      assert Errors.message({:referenced_by_smart_items, 3}) ==
               "Cannot delete: 3 smart items still reference this catalogue."
    end

    test "{:duplicate_referenced_catalogue, uuid}" do
      assert Errors.message({:duplicate_referenced_catalogue, "abc"}) ==
               "Each catalogue can only be referenced once per item."
    end

    test "{:invalid_price, raw}" do
      assert Errors.message({:invalid_price, "abc"}) == "Invalid price: abc"
    end

    test "{:invalid_markup, raw}" do
      assert Errors.message({:invalid_markup, "xyz"}) == "Invalid markup: xyz"
    end

    test "{:sheet_empty, sheet_name}" do
      assert Errors.message({:sheet_empty, "Sheet1"}) == "Sheet 'Sheet1' is empty."
    end

    test "{:sheet_read_failed, sheet, raw}" do
      assert Errors.message({:sheet_read_failed, "Sheet1", :timeout}) ==
               "Failed to read sheet 'Sheet1'."
    end

    test "{:xlsx_open_failed, raw}" do
      assert Errors.message({:xlsx_open_failed, :enoent}) == "Failed to open XLSX file."
    end

    test "{:xlsx_read_failed, raw}" do
      assert Errors.message({:xlsx_read_failed, :corrupt}) == "Failed to read XLSX file."
    end

    test "{:csv_parse_failed, raw}" do
      assert Errors.message({:csv_parse_failed, "bad row"}) == "Failed to parse CSV file."
    end

    # `{:pdftotext_failed, raw}` removed 2026-05-06 (Phase 2 sweep) —
    # the worker emits 4-arity `{:pdftotext_failed, page, code, msg}`
    # tuples internally and collapses them to a string via its own
    # `inspect_reason/1` helper before persisting; never routes
    # through `Errors.message/1`.
  end

  describe "message/1 — pass-through shapes" do
    test "Ecto.Changeset is returned unchanged" do
      changeset = Ecto.Changeset.change(%Ecto.Changeset{data: %{}, valid?: true})
      assert Errors.message(changeset) == changeset
    end

    test "binary string is returned unchanged" do
      assert Errors.message("legacy string error") == "legacy string error"
    end

    test "unknown atom falls through to inspect-rendered message" do
      assert Errors.message(:totally_unknown_atom) =~ "Unexpected error: :totally_unknown_atom"
    end

    test "raw map falls through to inspect-rendered message" do
      assert Errors.message(%{some: :map}) =~ "Unexpected error:"
    end
  end

  describe "message/1 — interpolation truncation" do
    test "long invalid_price values are truncated to 100 chars + ellipsis" do
      huge = String.duplicate("a", 5000)
      msg = Errors.message({:invalid_price, huge})
      # Allow for the trailing ellipsis character
      assert String.length(msg) < 200
      assert String.ends_with?(msg, "…")
    end

    test "non-binary raw values are inspect()'d before truncating" do
      msg = Errors.message({:invalid_price, %{a: 1, b: 2}})
      assert msg =~ "Invalid price:"
    end
  end
end
