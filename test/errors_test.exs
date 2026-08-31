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

    test "the two import-size atoms are pinned too (they were the only unpinned ones)" do
      # `parser.ex` returns both, and the parser tests assert the ATOM — but
      # nothing asserted the string a user actually reads, so these two were
      # the only members of @type error_atom with no pin.
      assert Errors.message(:file_too_large) ==
               "File is too large to import. Please split it into smaller files."

      assert Errors.message(:too_many_rows) ==
               "File has too many rows to import. Please split it into smaller files."
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

    test "cycle" do
      assert Errors.message(:cycle) ==
               "Can't move a folder into itself or one of its subfolders."
    end

    test "folder_not_found" do
      assert Errors.message(:folder_not_found) == "That folder no longer exists."
    end

    test "folder_trashed" do
      assert Errors.message(:folder_trashed) == "That folder is in the trash."
    end

    test "not_empty" do
      assert Errors.message(:not_empty) ==
               "Only empty folders can be deleted — move its contents out first."
    end

    test "invalid_entry" do
      assert Errors.message(:invalid_entry) == "Failed to save the new order."
    end

    test "contract_broken" do
      assert Errors.message(:contract_broken) ==
               "This set's configuration is invalid. Contact an administrator."
    end

    test "entities_disabled" do
      assert Errors.message(:entities_disabled) == "The attribute sets module is not enabled."
    end

    test "invalid_kind" do
      assert Errors.message(:invalid_kind) == "Invalid selection mode."
    end

    test "set_not_found" do
      assert Errors.message(:set_not_found) == "Attribute set not found."
    end

    test "set_in_use" do
      assert Errors.message(:set_in_use) ==
               "This set is attached to items — detach it everywhere first."
    end

    test "not_attached" do
      assert Errors.message(:not_attached) == "This set is not attached to the item."
    end

    test "label_required" do
      assert Errors.message(:label_required) == "Name is required."
    end

    test "invalid_type" do
      assert Errors.message(:invalid_type) == "Unsupported field type."
    end

    test "options_required" do
      assert Errors.message(:options_required) == "Add at least one choice."
    end

    test "duplicate_key" do
      assert Errors.message(:duplicate_key) == "A field with this name already exists."
    end

    test "unknown_field" do
      assert Errors.message(:unknown_field) == "Unknown field."
    end

    test "invalid_value" do
      assert Errors.message(:invalid_value) == "Invalid value."
    end

    test "already_linked" do
      assert Errors.message(:already_linked) ==
               "This supplier is already on the item. Edit the existing row instead."
    end

    test "wrong_catalogue_scope" do
      assert Errors.message(:wrong_catalogue_scope) ==
               "That selection is not in this catalogue."
    end

    test "invalid_uuid" do
      assert Errors.message(:invalid_uuid) == "That id is not valid."
    end

    test "files_folder" do
      assert Errors.message(:files_folder) == "Could not copy the files folder."
    end

    test "not_current" do
      assert Errors.message(:not_current) == "This supplier row is no longer current."
    end

    test "move_target_in_subtree" do
      assert Errors.message(:move_target_in_subtree) ==
               "Cannot move items into a category that is being deleted."
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
