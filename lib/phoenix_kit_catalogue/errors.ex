defmodule PhoenixKitCatalogue.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by `PhoenixKitCatalogue.Catalogue`
  and the import pipeline) to translated, user-facing strings.

  Keeping UI copy in one place means every "not found" / "delete failed" /
  "cycle" flash reads the same wording, and translations live in core's
  gettext backend rather than being scattered across LiveViews. Callers
  pattern-match on atoms (or tagged tuples for atoms with parameters);
  `message/1` wraps each mapping in `gettext/1` at the UI boundary.

  ## Supported reason shapes

    * plain atoms — `:would_create_cycle`, `:cross_catalogue`, etc.
    * tagged tuples — `{:referenced_by_smart_items, count}`,
      `{:duplicate_referenced_catalogue, uuid}`,
      `{:invalid_price, raw}`, `{:invalid_markup, raw}`,
      `{:sheet_empty, sheet}`, `{:sheet_read_failed, sheet, raw}`,
      `{:xlsx_open_failed, raw}`, `{:xlsx_read_failed, raw}`,
      `{:csv_parse_failed, raw}`
    * `Ecto.Changeset.t()` — passed through unchanged so callers can
      keep the changeset for `<.input>` rendering. UI flashes typically
      pull a summary via `Ecto.Changeset.traverse_errors/2`.
    * strings — passed through unchanged (legacy / interpolated messages)
    * anything else — rendered as `"Unexpected error: <inspect>"` so
      nothing silently surfaces a raw struct or tuple

  ## Example

      iex> PhoenixKitCatalogue.Errors.message(:would_create_cycle)
      "Cannot move a category under itself or one of its descendants."

      iex> PhoenixKitCatalogue.Errors.message({:referenced_by_smart_items, 3})
      "Cannot delete: 3 smart items still reference this catalogue."
  """

  alias Ecto.Changeset

  @typedoc """
  Atoms returned by the public `Catalogue` API and the import
  pipeline. Tagged tuples extend this set when an atom needs a
  parameter (`{:referenced_by_smart_items, count}`).
  """
  @type error_atom ::
          :would_create_cycle
          | :cross_catalogue
          | :parent_not_found
          | :not_siblings
          | :category_not_found
          | :catalogue_not_found
          | :same_catalogue
          | :no_user
          | :unsupported
          | :not_found
          | :missing_item_name
          | :unsupported_file_format
          | :csv_empty
          | :parent_catalogue_deleted

  @doc """
  Translates an error reason into a user-facing string via gettext.

  Use this at the UI boundary — typically inside `put_flash(:error, ...)`
  in a LiveView's `handle_event/3` clause. Context functions return
  raw atoms; the LV decides whether to surface the specific reason
  (via this helper) or a generic flash for unhandled shapes.
  """
  @spec message(term()) :: String.t()
  def message(:would_create_cycle),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Cannot move a category under itself or one of its descendants."
      )

  def message(:cross_catalogue),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Target belongs to a different catalogue. Move the category to the target catalogue first."
      )

  def message(:parent_not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Parent category not found.")

  def message(:not_siblings),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Categories must share the same parent to be reordered."
      )

  def message(:category_not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")

  def message(:catalogue_not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")

  def message(:same_catalogue),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Item is already in this catalogue."
      )

  def message(:no_user),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "You must be logged in to upload files."
      )

  def message(:unsupported),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unsupported file format.")

  def message(:unsupported_file_format),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Unsupported file format. Please upload .xlsx or .csv."
      )

  def message(:not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Not found.")

  def message(:missing_item_name),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Missing item name.")

  def message(:csv_empty),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "CSV file is empty.")

  def message(:parent_catalogue_deleted),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Cannot restore — the parent catalogue is deleted. Restore the catalogue first."
      )

  # Tagged tuples — atoms that carry a single parameter.

  def message({:referenced_by_smart_items, count}) when is_integer(count) do
    Gettext.gettext(
      PhoenixKitCatalogue.Gettext,
      "Cannot delete: %{count} smart items still reference this catalogue.",
      count: count
    )
  end

  def message({:duplicate_referenced_catalogue, _uuid}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Each catalogue can only be referenced once per item."
      )

  def message({:invalid_price, raw}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Invalid price: %{raw}",
        raw: truncate(raw)
      )

  def message({:invalid_markup, raw}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Invalid markup: %{raw}",
        raw: truncate(raw)
      )

  def message({:sheet_empty, sheet}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Sheet '%{sheet}' is empty.",
        sheet: to_string(sheet)
      )

  def message({:sheet_read_failed, sheet, _raw}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Failed to read sheet '%{sheet}'.",
        sheet: to_string(sheet)
      )

  def message({:xlsx_open_failed, _raw}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to open XLSX file.")

  def message({:xlsx_read_failed, _raw}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to read XLSX file.")

  def message({:csv_parse_failed, _raw}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to parse CSV file.")

  # PDF library error atoms removed 2026-05-06 (Phase 2 sweep) —
  # `:pdf_invalid_format` had no caller (the upload pipeline rejects
  # non-PDF MIME at the LV's `accept` attr, never via Errors).
  # `:pdf_extraction_failed` had no caller (worker stores the raw
  # message string in `error_message` and the LV renders it directly).
  # `{:pdftotext_failed, raw}` was 2-arity but the worker emits 4-arity
  # `{:pdftotext_failed, page, code, msg}` and collapses it to a string
  # via its own `inspect_reason/1` helper before persisting — never
  # routes through this module.

  # Pass-through for shapes that already carry user-renderable content.

  def message(%Changeset{} = changeset), do: changeset
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    Gettext.gettext(
      PhoenixKitCatalogue.Gettext,
      "Unexpected error: %{reason}",
      reason: inspect(reason)
    )
  end

  # Truncate raw values that ride into translated strings so a 5KB
  # blob doesn't end up in a flash. Keeps audit context (logs see the
  # full raw value via `log_operation_error/3`) while bounding UI surface.
  @spec truncate(term()) :: String.t()
  defp truncate(value) do
    str = if is_binary(value), do: value, else: inspect(value)

    if String.length(str) > 100 do
      String.slice(str, 0, 100) <> "…"
    else
      str
    end
  end
end
